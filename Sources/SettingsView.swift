import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var m: MixerModel

    var body: some View {
        Form {
            Section(m.t("General", "Général")) {
                Picker(m.t("Language", "Langue"), selection: $m.language) {
                    Text("English").tag(MixerModel.Language.en)
                    Text("Français").tag(MixerModel.Language.fr)
                }
                Toggle(m.t("Launch at login", "Ouvrir au démarrage"),
                       isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
            }

            Section {
                Picker(m.t("Maximum boost", "Boost maximum"), selection: $m.maxBoostDB) {
                    ForEach([6.0, 12.0, 18.0, 24.0], id: \.self) { Text("+\(Int($0)) dB").tag($0) }
                }
            } header: {
                Text(m.t("Volume", "Volume"))
            } footer: {
                Text(m.t("Above 100, faders boost up to this level. A soft limiter keeps peaks from clipping.",
                         "Au-delà de 100, les curseurs amplifient jusqu'à ce niveau. Un limiteur doux évite la saturation."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(m.t("Hidden apps", "Apps masquées")) {
                if m.hidden.isEmpty {
                    Text(m.t("No hidden apps. Right-click an app in the mixer to hide it.",
                             "Aucune app masquée. Fais un clic droit sur une app dans le mixeur pour la masquer."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(m.hidden.sorted(), id: \.self) { id in
                        HStack(spacing: 10) {
                            Image(nsImage: InstalledApp.icon(id)).resizable().frame(width: 20, height: 20)
                            Text(InstalledApp.name(id))
                            Spacer()
                            Button(m.t("Show", "Afficher")) { m.unhide(id) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Nom et icône d'une app à partir de son bundle ID, même si elle n'est pas lancée.
enum InstalledApp {
    private static func url(_ id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    static func name(_ id: String) -> String {
        guard let url = url(id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ id: String) -> NSImage {
        guard let url = url(id) else { return NSImage(systemSymbolName: "app", accessibilityDescription: nil)! }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
