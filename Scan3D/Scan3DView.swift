import SwiftUI
import ARKit
import SceneKit

/// Vista AR con i LED già ricostruiti come punti nello spazio.
struct ARPreview: UIViewRepresentable {
    let session: ARSession
    var points: [SIMD3<Float>]
    var colors: [SIMD4<Float>]

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = true
        v.scene = SCNScene()
        v.scene.rootNode.addChildNode(context.coordinator.node)
        return v
    }

    func updateUIView(_ v: ARSCNView, context: Context) {
        guard context.coordinator.count != points.count else { return }
        context.coordinator.count = points.count
        context.coordinator.node.geometry = points.isEmpty ? nil : LEDPointCloud.geometry(positions: points, colors: colors, pointSize: 14)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { let node = SCNNode(); var count = -1 }
}

struct Scan3DView: View {
    @EnvironmentObject var hub: ControllerHub

    var body: some View {
        Scan3DScreen(hub: hub)
    }
}

struct Scan3DScreen: View {
    @EnvironmentObject var hub: ControllerHub
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var carMaps: CarMapStore
    @StateObject var engine: ARScanEngine
    @State private var viewName = ""
    @State private var shutterIndex = 1
    @State private var colorIndex = 0
    @State private var mapName = ""
    @State private var saved: String?
    @State private var showSave = false

    private let suggestions = ["Davanti", "Anteriore sinistro", "Lato sinistro", "Posteriore sinistro",
                               "Dietro", "Posteriore destro", "Lato destro", "Anteriore destro", "Dall'alto"]
    private let shutters: [(String, Double)] = [("1/1000", 1.0 / 1000), ("1/500", 1.0 / 500), ("1/250", 1.0 / 250), ("1/125", 1.0 / 125)]
    private let colors: [(String, RGB)] = [("Verde", .green), ("Bianco", RGB(r: 255, g: 255, b: 255)), ("Blu", .blue)]

    init(hub: ControllerHub) {
        _engine = StateObject(wrappedValue: ARScanEngine(hub: hub))
    }

    private var nextSuggestion: String {
        let done = Set(engine.views.filter { $0.accepted }.map { $0.name })
        return suggestions.first { !done.contains($0) } ?? "Vista libera \(engine.views.count + 1)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                arCard
                controlCard
                coverageCard
                viewsCard
                tipsCard
                NavigationLink { ScanView() } label: {
                    Label("Scansione 2D rapida (una centralina, senza AR)", systemImage: "camera.viewfinder")
                        .font(.subheadline)
                }
                .padding(.bottom, 8)
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Scansione LED")
        .onAppear {
            engine.brightness = settings.diyBrightness
            engine.window = settings.sendWindow
            engine.startSession()
            if viewName.isEmpty { viewName = nextSuggestion }
        }
        .onDisappear {
            engine.cancel()
            engine.pauseSession()
        }
        .alert("Salva mappa", isPresented: $showSave) {
            TextField("Nome", text: $mapName)
            Button("Salva") { saveMap() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("\(engine.reconstructed.count) LED fisici ricostruiti. L'allineamento al modello si regola nella Mappa 3D.")
        }
    }

    // MARK: Card

    private var arCard: some View {
        Card(title: "Inquadratura AR", systemImage: "arkit") {
            let pts = engine.reconstructed.map { SIMD3<Float>(Float($0.position.x), Float($0.position.y), Float($0.position.z)) }
            let cols = engine.reconstructed.map { r -> SIMD4<Float> in
                let tint = hub.config(r.key.controller)?.tint ?? 0
                return LEDPointCloud.color(ControllerPalette.rgb(tint))
            }
            ARPreview(session: engine.session, points: pts, colors: cols)
                .frame(height: 380)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 8) {
                StatusDot(color: engine.trackingGood ? Theme.ok : Theme.warning, pulsing: !engine.trackingGood)
                Text(engine.trackingText).font(.caption)
                Spacer()
                Badge(text: engine.hasDepth ? "LIDAR: PROFONDITÀ" : "SENZA LIDAR: TRIANGOLAZIONE", color: engine.hasDepth ? Theme.ok : Theme.accent)
            }
            Text("I punti colorati sono i LED già localizzati nello spazio, con il colore della loro centralina.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private var controlCard: some View {
        Card(title: "Vista successiva", systemImage: "figure.walk.motion") {
            TextField("Nome vista", text: $viewName).textFieldStyle(.roundedBorder)
            Text("Suggerita: \(nextSuggestion). Posizionati lì, a 2–4 m dall'auto, e tieni il telefono fermo (meglio appoggiato) per tutta la sequenza.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Picker("Scatto", selection: $shutterIndex) {
                ForEach(shutters.indices, id: \.self) { Text(shutters[$0].0).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Colore", selection: $colorIndex) {
                ForEach(colors.indices, id: \.self) { Text(colors[$0].0).tag($0) }
            }.pickerStyle(.segmented)
            switch engine.phase {
            case .running(let step, let total, let label):
                ProgressView(value: Double(step - 1), total: Double(total)).tint(Theme.accent)
                Text("Fotogramma \(step)/\(total): \(label) · \(Int(engine.elapsed)) s").font(Theme.monoSmall)
                Button("Annulla vista") { engine.cancel() }.buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false))
            case .processing:
                Label("Analisi e ricostruzione…", systemImage: "cpu").font(.subheadline)
            default:
                Button {
                    saved = nil
                    engine.scanView(name: viewName.isEmpty ? nextSuggestion : viewName,
                                    color: colors[colorIndex].1, shutter: shutters[shutterIndex].1)
                } label: { Label("Scansiona questa vista", systemImage: "camera.metering.matrix") }
                    .buttonStyle(AccentButtonStyle())
                    .enabled(hub.allReady && engine.trackingGood)
                if case .failed(let reason) = engine.phase { Text(reason).font(.caption).foregroundStyle(Theme.danger) }
                if !hub.allReady {
                    Text("Collega e verifica tutte le centraline attive (sezione Centraline).").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            let book = hub.codebook
            Text("\(book.total) pixel su \(book.entries.count) centraline → \(book.plan.frames.count) fotogrammi per vista, tutte le centraline insieme (circa \(book.plan.frames.count * 3) s).")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .onChange(of: engine.views.count) { _ in viewName = nextSuggestion }
    }

    private var coverageCard: some View {
        Card(title: "Copertura", systemImage: "chart.bar.xaxis") {
            let found = Set(engine.reconstructed.map { $0.key })
            ForEach(hub.codebook.entries, id: \.controller) { e in
                let n = found.filter { $0.controller == e.controller }.count
                HStack {
                    RoundedRectangle(cornerRadius: 2).fill(ControllerPalette.color(hub.config(e.controller)?.tint ?? 0)).frame(width: 4, height: 18)
                    Text(hub.name(of: e.controller)).font(.subheadline)
                    Spacer()
                    Text("\(n)/\(e.count)").font(Theme.mono)
                }
                ProgressView(value: Double(n), total: Double(max(e.count, 1))).tint(ControllerPalette.color(hub.config(e.controller)?.tint ?? 0))
            }
            let lowConf = engine.reconstructed.filter { $0.confidence < 0.5 }.count
            Text("\(engine.reconstructed.count) LED fisici · \(lowConf) con affidabilità bassa (visti da una sola vista o dispersi). Aggiungi viste dalle zone mancanti per completare.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Button { mapName = "Audi A1 · \(Date().formatted(date: .abbreviated, time: .shortened))"; showSave = true } label: {
                    Label("Salva mappa", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(AccentButtonStyle())
                .enabled(!engine.reconstructed.isEmpty && !engine.phase.isBusy)
                if let active = carMaps.active, !active.isDemo, engine.views.isEmpty {
                    Button("Continua mappa") { engine.resume(from: active) }
                        .buttonStyle(AccentButtonStyle(filled: false))
                }
            }
            if let saved { Label("Salvata: \(saved)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.ok) }
        }
    }

    private var viewsCard: some View {
        Card(title: "Viste", systemImage: "square.stack.3d.down.right") {
            if engine.views.isEmpty { Text("Nessuna vista ancora.").font(.caption).foregroundStyle(Theme.textSecondary) }
            ForEach(engine.views) { v in
                HStack(alignment: .top) {
                    Image(systemName: v.accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(v.accepted ? Theme.ok : Theme.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.name).font(.subheadline)
                        Text("\(v.detections) punti · \(v.decoded) identificati · \(v.depthPoints) con profondità · mosso \(Int(v.movedCm)) cm")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                        if !v.note.isEmpty { Text(v.note).font(.caption2).foregroundStyle(Theme.warning) }
                    }
                    Spacer()
                    Button { engine.removeView(v.id) } label: { Image(systemName: "trash") }.foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var tipsCard: some View {
        Card(title: "Come scansionare", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Collega tutte le centraline e lascia l'auto ferma, al buio o in penombra.")
                Text("2. Per ogni vista appoggia il telefono: serve fermo per circa un minuto. Se si muove più di 5 cm la vista viene scartata.")
                Text("3. Gira intorno all'auto seguendo le viste suggerite: ogni LED dovrebbe essere visto almeno da due viste.")
                Text("4. Con LiDAR basta anche una vista per LED; senza LiDAR la posizione 3D si ottiene incrociando due o più viste.")
                Text("5. I LED in parallelo (a Y) compaiono come due posizioni dello stesso pixel: avranno sempre lo stesso colore.")
            }
            .font(.caption)
        }
    }

    private func saveMap() {
        let map = engine.makeMap(name: mapName.isEmpty ? "Audi A1" : mapName)
        carMaps.save(map)
        saved = map.name
    }
}
