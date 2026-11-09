import AudioToolbox
import CoreAudio
import Foundation

/// Capte l'audio d'une app (Process Tap), la coupe à la source, et la rejoue avec un gain
/// vers la sortie par défaut via un aggregate device privé.
final class AppTap {
    let processObjects: [AudioObjectID]
    let outputDevice: AudioDeviceID
    /// true = tap d'écoute seule (vumètre) : le son de l'app n'est ni coupé ni modifié.
    let meterOnly: Bool

    private var tapID = kUnknownObject
    private var aggID = kUnknownObject
    private var procID: AudioDeviceIOProcID?
    private var stopped = false

    // Lus par le thread audio : pas de lock, simples Float alignés.
    private let target = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let current = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init?(name: String, processObjects: [AudioObjectID], outputDevice: AudioDeviceID, gain: Float,
          meterOnly: Bool = false) {
        self.processObjects = processObjects
        self.outputDevice = outputDevice
        self.meterOnly = meterOnly
        target.pointee = gain
        current.pointee = gain
        peak.pointee = 0

        guard let outUID = CA.string(outputDevice, kAudioDevicePropertyDeviceUID) else { return nil }

        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.muteBehavior = meterOnly ? .unmuted : .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "AudioMixer \(name)"

        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { NSLog("AudioMixer: CreateProcessTap \(name) = \(err)"); return nil }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioMixer \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard err == noErr else { NSLog("AudioMixer: CreateAggregate \(name) = \(err)"); return nil }

        let t = target, c = current, p = peak
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
            if meterOnly {
                AppTap.meter(inData, outData, p)
            } else {
                AppTap.render(inData, outData, t, c, p)
            }
        }
        guard err == noErr else { NSLog("AudioMixer: CreateIOProc \(name) = \(err)"); return nil }
        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else { NSLog("AudioMixer: Start \(name) = \(err)"); return nil }
    }

    func setGain(_ g: Float) { target.pointee = g }

    /// Niveau crête depuis la dernière lecture (0…1), pour le vumètre.
    func readPeak() -> Float {
        let v = peak.pointee
        peak.pointee = 0
        return v
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if aggID != kUnknownObject {
            if let procID {
                AudioDeviceStop(aggID, procID)
                AudioDeviceDestroyIOProcID(aggID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kUnknownObject { AudioHardwareDestroyProcessTap(tapID) }
    }

    deinit {
        stop()
        target.deallocate()
        current.deallocate()
        peak.deallocate()
    }

    // MARK: - Thread audio

    @inline(__always) private static func softClip(_ x: Float) -> Float {
        let ax = abs(x)
        guard ax > 0.8 else { return x }
        return (x < 0 ? -1 : 1) * (0.8 + 0.2 * tanhf((ax - 0.8) / 0.2))
    }

    /// Écoute seule : mesure la crête du tap, sortie silencieuse (l'app joue normalement).
    private static func meter(_ inData: UnsafePointer<AudioBufferList>,
                              _ outData: UnsafeMutablePointer<AudioBufferList>,
                              _ peak: UnsafeMutablePointer<Float>) {
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard ins.count > 0, let raw = ins[ins.count - 1].mData else { return }
        let src = raw.assumingMemoryBound(to: Float.self)
        let n = Int(ins[ins.count - 1].mDataByteSize) / MemoryLayout<Float>.size
        var pk = peak.pointee
        for i in 0..<n {
            let a = abs(src[i])
            if a > pk { pk = a }
        }
        peak.pointee = pk
    }

    private static func render(_ inData: UnsafePointer<AudioBufferList>,
                               _ outData: UnsafeMutablePointer<AudioBufferList>,
                               _ target: UnsafeMutablePointer<Float>,
                               _ current: UnsafeMutablePointer<Float>,
                               _ peak: UnsafeMutablePointer<Float>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }

        // Le tap est le dernier flux d'entrée de l'aggregate (après les entrées éventuelles du périphérique).
        guard ins.count > 0 else { return }
        let inBuf = ins[ins.count - 1]
        guard let srcRaw = inBuf.mData else { return }
        let src = srcRaw.assumingMemoryBound(to: Float.self)
        let inCh = max(1, Int(inBuf.mNumberChannels))
        let frames = Int(inBuf.mDataByteSize) / (MemoryLayout<Float>.size * inCh)
        guard frames > 0 else { return }

        let g0 = current.pointee, g1 = target.pointee
        let step = (g1 - g0) / Float(frames)
        var pk: Float = peak.pointee
        var chBase = 0

        for b in outs {
            let chs = max(1, Int(b.mNumberChannels))
            defer { chBase += chs }
            guard chBase < 2, let dRaw = b.mData else { continue }
            let dst = dRaw.assumingMemoryBound(to: Float.self)
            let n = min(frames, Int(b.mDataByteSize) / (MemoryLayout<Float>.size * chs))
            for f in 0..<n {
                let g = g0 + step * Float(f)
                for c in 0..<chs {
                    let global = chBase + c
                    if global >= 2 { break }
                    let s = softClip(src[f * inCh + min(global, inCh - 1)] * g)
                    dst[f * chs + c] = s
                    let a = abs(s)
                    if a > pk { pk = a }
                }
            }
        }
        current.pointee = g1
        peak.pointee = pk
    }
}
