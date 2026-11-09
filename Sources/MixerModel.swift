import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

struct MixerApp: Identifiable, Equatable {
    let id: String          // bundle ID
    let name: String
    let icon: NSImage
    var objects: [AudioObjectID]
    var isPlaying: Bool

    static func == (a: MixerApp, b: MixerApp) -> Bool {
        a.id == b.id && a.name == b.name && a.objects == b.objects && a.isPlaying == b.isPlaying
    }
}

final class MixerModel: ObservableObject {
    @Published var apps: [MixerApp] = []
    @Published var volumes: [String: Double]   // position du curseur 0…2 (1 = 100 %, >1 = boost)
    @Published var muted: Set<String>
    @Published var levels: [String: Float] = [:]
    @Published var maxBoostDB: Double {
        didSet { save(); apps.forEach(reconcile) }
    }
    @Published var deviceName = ""
    @Published var masterVolume: Double = 0
    @Published var masterMuted = false
    @Published var masterAvailable = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var hidden: Set<String>          // apps masquées à la main

    // MARK: Langue (anglais par défaut)
    enum Language: String { case en, fr }
    @Published var language: Language = Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .en {
        didSet { defaults.set(language.rawValue, forKey: "language"); refreshDevice() }
    }
    func t(_ en: String, _ fr: String) -> String { language == .fr ? fr : en }

    /// Process système qui ouvrent l'audio mais n'ont rien à faire dans un mixeur.
    private static let systemBundleIDs: Set<String> = [
        "com.apple.controlcenter", "com.apple.PowerChime", "com.apple.loginwindow",
        "com.apple.notificationcenterui", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.WindowManager", "com.apple.Siri", "com.apple.accessibility.heard",
    ]

    private var taps: [String: AppTap] = [:]
    private var failed: Set<String> = []
    private var pendingRemoval: [String: DispatchWorkItem] = [:]
    private var outputDevice = AudioDeviceID(0)
    private var timers: [Timer] = []
    private let defaults = UserDefaults.standard
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    init() {
        volumes = defaults.dictionary(forKey: "volumes") as? [String: Double] ?? [:]
        muted = Set(defaults.stringArray(forKey: "muted") ?? [])
        hidden = Set(defaults.stringArray(forKey: "hidden") ?? [])
        let b = defaults.double(forKey: "maxBoostDB")
        maxBoostDB = b == 0 ? 12 : b

        // Premier lancement : ouverture au démarrage activée par défaut (désactivable ensuite).
        if !defaults.bool(forKey: "loginItemConfigured") {
            defaults.set(true, forKey: "loginItemConfigured")
            try? SMAppService.mainApp.register()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }

        refreshDevice()
        refreshApps()
        installListeners()

        timers.append(Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshApps()
            self?.refreshMaster()
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            self?.refreshLevels()
        })
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.taps.values.forEach { $0.stop() }
        }
    }

    // MARK: - Courbes

    func gain(forPosition v: Double) -> Double {
        v <= 1 ? v * v : pow(10, (v - 1) * maxBoostDB / 20)
    }

    func label(forPosition v: Double) -> String {
        v <= 1 ? "\(Int((v * 100).rounded()))" : String(format: "+%.1f dB", (v - 1) * maxBoostDB)
    }

    private func effectiveGain(_ id: String) -> Double {
        muted.contains(id) ? 0 : gain(forPosition: volumes[id] ?? 1)
    }

    // MARK: - Actions UI

    func volume(_ id: String) -> Double { volumes[id] ?? 1 }

    func setVolume(_ id: String, _ v: Double) {
        volumes[id] = v
        if let app = apps.first(where: { $0.id == id }) { reconcile(app) }
        save()
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        if let app = apps.first(where: { $0.id == id }) { reconcile(app) }
        save()
    }

    func setMaster(_ v: Double) {
        masterVolume = v
        CA.setMasterVolume(outputDevice, Float(v))
    }

    func toggleMasterMute() {
        CA.setMuted(outputDevice, !masterMuted)
        masterMuted = CA.isMuted(outputDevice)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AudioMixer: login item \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func hide(_ id: String) {
        hidden.insert(id)
        save()
        refreshApps()
    }

    func unhideAll() {
        hidden.removeAll()
        save()
        refreshApps()
    }

    private func save() {
        defaults.set(volumes, forKey: "volumes")
        defaults.set(Array(muted), forKey: "muted")
        defaults.set(Array(hidden), forKey: "hidden")
        defaults.set(maxBoostDB, forKey: "maxBoostDB")
    }

    // MARK: - Synchronisation Core Audio

    private func refreshDevice() {
        outputDevice = CA.defaultOutputDevice()
        deviceName = CA.string(outputDevice, kAudioObjectPropertyName) ?? t("Output", "Sortie")
        refreshMaster()
    }

    private func refreshMaster() {
        if let v = CA.masterVolume(outputDevice) {
            masterAvailable = true
            if abs(Double(v) - masterVolume) > 0.005 { masterVolume = Double(v) }
        } else {
            masterAvailable = false
        }
        let m = CA.isMuted(outputDevice)
        if m != masterMuted { masterMuted = m }
    }

    private func refreshLevels() {
        guard !taps.isEmpty else {
            if !levels.isEmpty { levels = [:] }
            return
        }
        var new: [String: Float] = [:]
        for (id, tap) in taps {
            let p = tap.readPeak()
            new[id] = max(p, (levels[id] ?? 0) * 0.82)   // décroissance douce
        }
        levels = new
    }

    func refreshApps() {
        var groups: [String: (app: NSRunningApplication, objs: [AudioObjectID], playing: Bool)] = [:]
        for p in CA.processes() where p.pid > 0 && p.pid != selfPID {
            guard let app = AppResolver.app(for: p), let bid = app.bundleIdentifier,
                  app.processIdentifier != selfPID else { continue }
            var g = groups[bid] ?? (app, [], false)
            g.objs.append(p.objectID)
            g.playing = g.playing || p.isRunningOutput
            groups[bid] = g
        }

        // Visible : app classique (Dock), ou app de barre de menus qui joue / a un volume réglé.
        let visible = groups.filter { bid, g in
            guard !hidden.contains(bid), !Self.systemBundleIDs.contains(bid) else { return false }
            return g.app.activationPolicy == .regular || g.playing
                || volumes[bid].map { $0 != 1 } ?? false || muted.contains(bid)
        }

        let new = visible.map { bid, g in
            MixerApp(id: bid,
                     name: g.app.localizedName ?? bid,
                     icon: g.app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!,
                     objects: g.objs.sorted(),
                     isPlaying: g.playing)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if new != apps { apps = new }
        new.forEach(reconcile)

        for id in taps.keys where visible[id] == nil {
            taps[id]?.stop()
            taps[id] = nil
        }
    }

    private enum TapMode { case none, meter, process }

    /// Tap « process » si le gain ≠ 100 % (son modifié), tap « meter » si l'app joue à 100 %
    /// (vumètre seulement, son intact), aucun tap sinon.
    private func reconcile(_ app: MixerApp) {
        let id = app.id
        let g = effectiveGain(id)
        let desired: TapMode = g != 1 ? .process : (app.isPlaying ? .meter : .none)
        let tap = taps[id]
        let current: TapMode = tap.map { $0.meterOnly ? .meter : .process } ?? .none
        let sameTarget = tap.map { $0.processObjects == app.objects && $0.outputDevice == outputDevice } ?? false

        switch desired {
        case .process:
            cancelPending(id)
            if let tap, current == .process, sameTarget { tap.setGain(Float(g)); return }
            makeTap(app, gain: Float(g), meterOnly: false)

        case .meter where current == .process, .none where current == .process:
            // Retour à 100 % : on garde le tap 1 s pour éviter les coupures pendant un glissement.
            tap?.setGain(1)
            schedule(id, after: 1)

        case .meter:
            cancelPending(id)
            if current == .meter, sameTarget { return }
            makeTap(app, gain: 1, meterOnly: true)

        case .none:
            if current == .meter { schedule(id, after: 3) }   // l'app s'est tue
        }
    }

    private func makeTap(_ app: MixerApp, gain: Float, meterOnly: Bool) {
        let key = "\(app.id)|\(app.objects)|\(outputDevice)|\(meterOnly)"
        guard !failed.contains(key) else { return }
        taps[app.id]?.stop()
        taps[app.id] = nil
        if let tap = AppTap(name: app.id, processObjects: app.objects, outputDevice: outputDevice,
                            gain: gain, meterOnly: meterOnly) {
            taps[app.id] = tap
        } else {
            failed.insert(key)
        }
    }

    /// Retire le tap après un délai, puis réévalue (ex. passer de « process » à « meter »).
    private func schedule(_ id: String, after seconds: Double) {
        guard pendingRemoval[id] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRemoval[id] = nil
            self.taps[id]?.stop()
            self.taps[id] = nil
            if let app = self.apps.first(where: { $0.id == id }) { self.reconcile(app) }
        }
        pendingRemoval[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelPending(_ id: String) {
        pendingRemoval[id]?.cancel()
        pendingRemoval[id] = nil
    }

    private func installListeners() {
        var dev = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &dev, .main) { [weak self] _, _ in
            guard let self else { return }
            self.taps.values.forEach { $0.stop() }
            self.taps.removeAll()
            self.failed.removeAll()
            self.refreshDevice()
            self.refreshApps()
        }
        var list = CA.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(CA.system, &list, .main) { [weak self] _, _ in
            self?.refreshApps()
        }
    }
}
