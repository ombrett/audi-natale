import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case studio, map3D, controllers, more
    var id: String { rawValue }
    var title: String {
        switch self {
        case .studio: return "Studio"
        case .map3D: return "Mappa 3D"
        case .controllers: return "Centraline"
        case .more: return "Altro"
        }
    }
    var icon: String {
        switch self {
        case .studio: return "cube"
        case .map3D: return "square.3.layers.3d"
        case .controllers: return "server.rack"
        case .more: return "ellipsis.circle"
        }
    }
}

/// Contenitore principale: Studio, Mappa 3D, Centraline, Altro (effetti, preset salvati, impostazioni, strumenti).
struct MainShell: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var carMaps: CarMapStore
    @EnvironmentObject var hub: ControllerHub
    @EnvironmentObject var ui: AppUIState

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Le sezioni restano in vita (niente ricostruzione della scena 3D al cambio di scheda).
                NavigationStack { StudioView() }.opacity(ui.section == .studio ? 1 : 0).allowsHitTesting(ui.section == .studio)
                if ui.section == .map3D { NavigationStack { Studio3DView() } }
                if ui.section == .controllers { NavigationStack { ControllersView() } }
                if ui.section == .more { NavigationStack { MoreView() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TabBar(section: $ui.section)
        }
        .background(Theme.background.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .onAppear { syncSending(); DebugLaunch.run(ui: ui, player: player, carMaps: carMaps, hub: hub) }
        .onChange(of: settings.diyBrightness) { _ in syncSending() }
        .onChange(of: settings.sendWindow) { _ in syncSending() }
        .onChange(of: carMaps.activeID) { _ in player.setMap(carMaps.active); ui.studioSelection = nil }
        .onChange(of: hub.controllers) { _ in player.setMap(carMaps.active) }
    }

    private func syncSending() {
        player.brightness = settings.diyBrightness
        player.window = settings.sendWindow
        player.setMap(carMaps.active)
    }
}

private struct TabBar: View {
    @Binding var section: MainSection

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                ForEach(MainSection.allCases) { s in
                    Button { section = s } label: {
                        VStack(spacing: 4) {
                            Image(systemName: s.icon).font(.system(size: 20, weight: .regular))
                            Text(s.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                        .foregroundStyle(section == s ? Theme.accent : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tab-\(s.rawValue)")
                }
            }
        }
        .background(Theme.background.ignoresSafeArea(edges: .bottom))
    }
}
