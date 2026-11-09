import SwiftUI

// MARK: - Fenêtre principale (popover de la barre de menus)

struct MixerView: View {
    @EnvironmentObject var m: MixerModel

    private var width: CGFloat {
        let apps = CGFloat(max(m.apps.count, 3)) * 86
        return min(max(110 + apps + 30, 640), 960)   // 640 min : le pied de fenêtre tient sur une ligne
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                section(m.t("Device", "Périphérique")) { masterColumn }
                    .padding(.leading, 8)
                Divider().padding(.vertical, 8)
                section(m.t("Applications", "Applications")) {
                    if m.apps.isEmpty {
                        Text(m.t("No app is using audio", "Aucune application audio"))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(spacing: 2) {
                                ForEach(m.apps) { app in appColumn(app) }
                            }
                            .padding(.trailing, 8)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: width)
    }

    private var header: some View {
        HStack {
            Image(systemName: "slider.vertical.3")
            Text(m.t("Volume Mixer", "Mélangeur de volume")).font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { m.openSettings?() } label: {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(m.t("Settings", "Réglages"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.leading, 8).padding(.top, 8)
            content()
        }
    }

    private var masterColumn: some View {
        ChannelColumn(
            icon: Image(systemName: "hifispeaker.fill"),
            iconIsSymbol: true,
            title: m.deviceName,
            playing: false,
            level: 0,
            value: Binding(get: { m.masterVolume }, set: { m.setMaster($0) }),
            maxValue: 1,
            label: "\(Int((m.masterVolume * 100).rounded()))",
            muted: m.masterMuted,
            enabled: m.masterAvailable,
            onMute: m.toggleMasterMute,
            onReset: nil
        )
    }

    private func appColumn(_ app: MixerApp) -> some View {
        let v = m.volume(app.id)
        return ChannelColumn(
            icon: Image(nsImage: app.icon),
            iconIsSymbol: false,
            title: app.name,
            playing: app.isPlaying,
            level: m.levels[app.id] ?? 0,
            value: Binding(get: { m.volume(app.id) }, set: { m.setVolume(app.id, $0) }),
            maxValue: 2,
            label: m.label(forPosition: v),
            muted: m.muted.contains(app.id),
            enabled: true,
            onMute: { m.toggleMute(app.id) },
            onReset: { m.setVolume(app.id, 1) }
        )
        .contextMenu {
            Button(m.t("Reset to 100", "Remettre à 100")) { m.setVolume(app.id, 1) }
            Button(m.t("Hide \(app.name)", "Masquer \(app.name)")) { m.hide(app.id) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Boost max").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            Picker("", selection: $m.maxBoostDB) {
                ForEach([6.0, 12.0, 18.0, 24.0], id: \.self) { Text("+\(Int($0)) dB").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220).controlSize(.small)
            Spacer(minLength: 8)
            if !m.hidden.isEmpty {
                Button(m.t("Show hidden (\(m.hidden.count))", "Réafficher (\(m.hidden.count))")) { m.unhideAll() }
                    .buttonStyle(.link).font(.system(size: 11)).fixedSize()
            }
            Toggle(m.t("Launch at login", "Ouvrir au démarrage"),
                   isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).font(.system(size: 11)).fixedSize()
            Button(m.t("Quit", "Quitter")) { NSApp.terminate(nil) }.controlSize(.small).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - Colonne façon mélangeur Windows

struct ChannelColumn: View {
    let icon: Image
    let iconIsSymbol: Bool
    let title: String
    let playing: Bool
    let level: Float
    @Binding var value: Double
    let maxValue: Double
    let label: String
    let muted: Bool
    let enabled: Bool
    let onMute: () -> Void
    let onReset: (() -> Void)?

    @EnvironmentObject private var m: MixerModel
    @State private var hover = false

    private var speakerSymbol: String {
        if muted { return "speaker.slash.fill" }
        switch value {
        case 0: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if iconIsSymbol {
                    icon.font(.system(size: 22)).foregroundStyle(.secondary)
                } else {
                    icon.resizable().interpolation(.high)
                }
            }
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottomTrailing) {
                if playing {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }

            Text(title)
                .font(.system(size: 11))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 78, height: 28, alignment: .top)

            HStack(spacing: 4) {
                VolumeSlider(value: $value, maxValue: maxValue)
                    .frame(width: 26, height: 170)
                LevelMeter(level: level)
                    .frame(width: 5, height: 170)
                    .opacity(maxValue > 1 ? 1 : 0)
            }
            .opacity(muted || !enabled ? 0.45 : 1)
            .allowsHitTesting(enabled)

            Text(label)
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(value > 1 ? Color.orange : Color.primary)
                .frame(height: 14)
                .onTapGesture(count: 2) { onReset?() }
                .help(onReset == nil ? "" : m.t("Double-click to reset to 100", "Double-clic : revenir à 100"))

            Button(action: onMute) {
                Image(systemName: speakerSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(muted ? Color.red : Color.secondary)
                    .frame(width: 30, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? m.t("Unmute", "Réactiver le son") : m.t("Mute", "Couper le son"))
        }
        .padding(.vertical, 10)
        .frame(width: 84)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
    }
}

// MARK: - Curseur vertical

struct VolumeSlider: View {
    @Binding var value: Double
    let maxValue: Double   // 1 = sans boost, 2 = zone de boost au-dessus de 100

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let frac = min(max(value / maxValue, 0), 1)
            let y = h * (1 - frac)
            let unityY = h * (1 - 1 / maxValue)

            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.15)).frame(width: 4, height: h)
                if maxValue > 1 {
                    Capsule().fill(Color.orange.opacity(0.22)).frame(width: 4, height: unityY)
                }
                Capsule()
                    .fill(value > 1 ? Color.orange : Color.accentColor)
                    .frame(width: 4, height: max(h - y, 0))
                    .offset(y: y)
                if maxValue > 1 {
                    Rectangle().fill(Color.primary.opacity(0.35))
                        .frame(width: 16, height: 1).offset(y: unityY)
                }
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .controlColor))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: 22, height: 10)
                    .offset(y: y - 5)
            }
            .frame(width: geo.size.width, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    var v = (1 - g.location.y / h) * maxValue
                    v = min(max(v, 0), maxValue)
                    if maxValue > 1, abs(v - 1) < 0.03 { v = 1 }   // aimant à 100
                    value = v
                }
            )
            .background(ScrollCatcher { delta in
                value = min(max(value + delta * 0.01, 0), maxValue)
            })
        }
    }
}

// MARK: - Vumètre

struct LevelMeter: View {
    let level: Float

    /// Échelle en dB (-54…0 dBFS) : la barre bouge sur toute sa hauteur, comme sous Windows.
    private var fraction: CGFloat {
        guard level > 0.002 else { return 0 }
        let db = 20 * log10(Double(min(level, 1)))
        return CGFloat(min(max((db + 54) / 54, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height * fraction
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height)
                    .mask(alignment: .bottom) { Rectangle().frame(height: h) }
            }
        }
        .animation(.linear(duration: 0.05), value: level)
    }
}

// MARK: - Molette / trackpad sur le curseur

struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ScrollView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollView)?.onScroll = onScroll
    }

    final class ScrollView: NSView {
        var onScroll: ((Double) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.25 : event.scrollingDeltaY * 2
            onScroll?(Double(d))
        }
    }
}
