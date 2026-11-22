import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case dashboard, controllers, scan, map3D, effects, presets, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Home"
        case .controllers: return "Centraline"
        case .scan: return "Scansione"
        case .map3D: return "Mappa 3D"
        case .effects: return "Effetti"
        case .presets: return "Preset"
        case .settings: return "Impostazioni"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .controllers: return "cpu.fill"
        case .scan: return "viewfinder"
        case .map3D: return "car.side.fill"
        case .effects: return "wand.and.rays"
        case .presets: return "square.stack.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Contenitore principale con barra di navigazione personalizzata a 7 sezioni.
struct MainShell: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var carMaps: CarMapStore
    @State private var section: MainSection = .dashboard

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch section {
                case .dashboard: NavigationStack { HomeView(section: $section) }
                case .controllers: NavigationStack { ControllersView() }
                case .scan: NavigationStack { Scan3DView() }
                case .map3D: NavigationStack { Studio3DView() }
                case .effects: NavigationStack { EffectsStudioView() }
                case .presets: NavigationStack { PresetsView(section: $section) }
                case .settings: NavigationStack { SettingsView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 62) }

            TabBar(section: $section)
        }
        .ignoresSafeArea(.keyboard)
        .onAppear(perform: syncSending)
        .onChange(of: settings.diyBrightness) { _ in syncSending() }
        .onChange(of: settings.sendWindow) { _ in syncSending() }
        .onChange(of: carMaps.activeID) { _ in player.setMap(carMaps.active) }
    }

    private func syncSending() {
        player.brightness = settings.diyBrightness
        player.window = settings.sendWindow
        player.setMap(carMaps.active)
    }
}

private struct TabBar: View {
    @Binding var section: MainSection
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainSection.allCases) { s in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { section = s }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: s.icon).font(.system(size: 17, weight: .semibold))
                        Text(s.title).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(section == s ? Theme.accent : Theme.textSecondary)
                    .background {
                        if section == s {
                            RoundedRectangle(cornerRadius: 12).fill(Theme.accentDim).matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}
