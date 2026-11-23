import SwiftUI

struct HomeView: View {
    @EnvironmentObject var hub: ControllerHub
    @EnvironmentObject var carMaps: CarMapStore
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var model: CarModelStore
    @EnvironmentObject var ui: AppUIState
    @State private var camToken = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                controllersCard
                mapCard
                flowCard
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Panoramica")
        .onAppear { player.setMap(carMaps.active) }
    }

    private var hero: some View {
        let (content, _) = SceneContentBuilder.build(map: carMaps.active, colors: player.colors, coloring: .effect, filter: .all,
                                                      controllers: hub.controllers, model: model)
        return ZStack(alignment: .bottomLeading) {
            CarSceneView(content: content, camera: .iso, cameraToken: camToken, onSelect: nil)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
            VStack(alignment: .leading, spacing: 4) {
                Text("Audi A1 Sportback").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    if model.isProvisional { Badge(text: "MODELLO PROVVISORIO", color: Theme.warning) }
                    if carMaps.active?.isDemo == true { Badge(text: "MAPPA DIMOSTRATIVA", color: Theme.warning) }
                    if carMaps.active?.isDesign == true { Badge(text: "MAPPA DA PROGETTO", color: Theme.warning) }
                }
            }
            .padding(14)
        }
    }

    private var controllersCard: some View {
        Card(title: "Centraline", systemImage: "cpu") {
            if hub.controllers.isEmpty {
                Text("Nessuna centralina configurata.").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Button("Aggiungi centraline") { ui.section = .controllers }.buttonStyle(AccentButtonStyle())
            } else {
                HStack {
                    ForEach(hub.orderedLinks) { link in
                        VStack(spacing: 4) {
                            Circle().fill(link.isReady ? Theme.ok : (link.state.isBusy ? Theme.warning : Theme.surfaceHigh))
                                .frame(width: 12, height: 12)
                            Text(link.config.name).font(.caption2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack {
                    Text("\(hub.readyLinks.count)/\(hub.enabledControllers.count) pronte · \(hub.totalLEDs) pixel logici")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                Button(hub.allReady ? "Tutte collegate" : "Collega tutte") { hub.connectAll() }
                    .buttonStyle(AccentButtonStyle(filled: !hub.allReady))
                    .enabled(!hub.allReady && hub.bluetoothState == .poweredOn)
            }
        }
    }

    private var mapCard: some View {
        Card(title: "Mappa LED", systemImage: "point.3.filled.connected.trianglepath.dotted") {
            if let m = carMaps.active {
                let cov = m.coverage(codebook: hub.codebook)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name).font(.subheadline.weight(.semibold))
                        Text("\(m.leds.count) LED fisici · \(cov.found)/\(cov.total) pixel · \(m.viewCount) viste")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                ProgressView(value: Double(cov.found), total: Double(max(cov.total, 1))).tint(Theme.accent)
            } else {
                Text("Nessuna mappa: scansiona l'auto con le luci montate, oppure crea una mappa dimostrativa dalla Mappa 3D.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var flowCard: some View {
        Card(title: "Flusso", systemImage: "arrow.triangle.turn.up.right.circle") {
            step(1, "Collega le centraline", done: hub.allReady) { ui.section = .controllers }
            step(2, "Scansiona l'auto", done: carMaps.active.map { $0.isMeasured } ?? false) { ui.section = .map3D }
            step(3, "Controlla la mappa 3D", done: false) { ui.section = .map3D }
            step(4, "Scegli un effetto, anteprima e Live", done: player.isPlaying) { ui.section = .studio }
        }
    }

    private func step(_ n: Int, _ title: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(done ? Theme.ok.opacity(0.2) : Theme.accentDim).frame(width: 30, height: 30)
                    if done { Image(systemName: "checkmark").foregroundStyle(Theme.ok) } else { Text("\(n)").foregroundStyle(Theme.accent) }
                }
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}
