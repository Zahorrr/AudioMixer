import AppKit
import SwiftUI

@main
struct AudioMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // ⌘, depuis le menu de l'app
    var body: some Scene { Settings { SettingsView().environmentObject(delegate.model) } }
}

/// Icône de barre de menus : clic gauche = mélangeur, clic droit (ou ctrl-clic) = menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MixerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.openSettings = { [weak self] in self?.openSettings() }

        let host = NSHostingController(rootView: MixerView().environmentObject(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "AudioMixer")
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }

    /// Menu natif sous l'icône (même rendu que Slack & co) : attaché le temps d'un clic.
    private func showMenu(from button: NSStatusBarButton) {
        popover.performClose(nil)
        let menu = NSMenu()

        menu.addItem(withTitle: model.t("Settings…", "Réglages…"), action: #selector(openSettings), keyEquivalent: ",").target = self

        let languages = NSMenu()
        for (lang, title) in [(MixerModel.Language.en, "English"), (.fr, "Français")] {
            let item = languages.addItem(withTitle: title, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = model.language == lang ? .on : .off
        }
        let langItem = menu.addItem(withTitle: model.t("Language", "Langue"), action: nil, keyEquivalent: "")
        menu.setSubmenu(languages, for: langItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: model.t("Quit", "Quitter"), action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = MixerModel.Language(rawValue: raw) else { return }
        model.language = lang
    }

    /// Fenêtre de réglages gérée ici : depuis macOS 14, SwiftUI n'ouvre plus la scène Settings
    /// depuis du code AppKit (clic droit, bouton du mixeur).
    @objc private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = model.t("AudioMixer Settings", "Réglages d'AudioMixer")
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
