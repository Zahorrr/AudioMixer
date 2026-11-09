import AppKit
import AudioToolbox
import CoreAudio
import Foundation

let kUnknownObject = AudioObjectID(kAudioObjectUnknown)

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ sel: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
        var a = address(sel, scope: scope), v = def, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : def
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = address(sel), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var str: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &str) == noErr, let str else { return nil }
        return str.takeRetainedValue() as String
    }

    static func objectList(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(sel), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func processes() -> [AudioProcess] {
        objectList(system, kAudioHardwarePropertyProcessObjectList).map { o in
            AudioProcess(objectID: o,
                         pid: get(o, kAudioProcessPropertyPID, pid_t(-1)),
                         bundleID: string(o, kAudioProcessPropertyBundleID),
                         isRunningOutput: get(o, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0)
        }
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        get(system, kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
    }

    // MARK: Volume principal du périphérique

    static func masterVolume(_ dev: AudioDeviceID) -> Float? {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioHardwareServiceHasProperty(dev, &a) else { return nil }
        var v: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        return AudioHardwareServiceGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setMasterVolume(_ dev: AudioDeviceID, _ value: Float) {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var v = Float32(min(max(value, 0), 1))
        AudioHardwareServiceSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted(_ dev: AudioDeviceID) -> Bool {
        get(dev, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, UInt32(0)) != 0
    }

    static func setMuted(_ dev: AudioDeviceID, _ muted: Bool) {
        var a = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}

/// Retrouve l'app « propriétaire » d'un process audio (Chrome Helper -> Chrome, WebKit.GPU -> Safari…)
enum AppResolver {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    private static func usable(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard let app, app.activationPolicy != .prohibited, app.bundleIdentifier != nil else { return nil }
        return app
    }

    /// Chemin de l'exécutable d'un process.
    private static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Helper imbriqué (…/Claude.app/Contents/Frameworks/…/Claude Helper.app) -> l'app la plus externe.
    private static func outerApp(of pid: pid_t) -> NSRunningApplication? {
        guard let path = executablePath(pid), let range = path.range(of: ".app/") else { return nil }
        let outer = String(path[..<range.lowerBound]) + ".app"
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.path == outer && $0.bundleIdentifier != nil
        }
    }

    static func app(for p: AudioProcess) -> NSRunningApplication? {
        // 1. process responsable (Chrome Helper -> Chrome, WebKit -> Safari)
        if let fn = responsible {
            let r = fn(p.pid)
            if r > 0, r != p.pid, let a = NSRunningApplication(processIdentifier: r),
               a.activationPolicy == .regular, a.bundleIdentifier != nil { return a }
        }
        // 2. helper rangé dans le bundle d'une autre app
        if let a = outerApp(of: p.pid) { return a }
        // 3. le process lui-même
        if let a = usable(NSRunningApplication(processIdentifier: p.pid)) { return a }
        // 4. préfixe de bundle ID
        guard let bid = p.bundleID else { return nil }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && ($0.bundleIdentifier.map { bid.hasPrefix($0 + ".") } ?? false) }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }
}
