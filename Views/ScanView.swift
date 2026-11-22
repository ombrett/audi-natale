import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Punti mappati sopra un'immagine (coordinate normalizzate).
struct PointsOverlay: View {
    let points: [MappedPoint]
    var selected: UUID?
    var showLabels = true

    var body: some View {
        GeometryReader { geo in
            ForEach(points) { p in
                let isSel = p.id == selected
                let color: Color = p.index == nil ? Theme.danger : (p.manual ? Theme.warning : Theme.accent)
                ZStack {
                    Circle().stroke(color, lineWidth: isSel ? 3 : 1.5)
                        .frame(width: isSel ? 18 : 10, height: isSel ? 18 : 10)
                    if showLabels {
                        Text(p.index.map { "\($0)" } ?? "?")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(color)
                            .offset(y: -10)
                    }
                }
                .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}

struct ScanView: View {
    @EnvironmentObject var ideal: IdealController
    @EnvironmentObject var settings: AppSettings
    @StateObject private var camera = CameraCapture()
    @State private var engine: MappingEngine?

    var body: some View {
        Group {
            if let engine {
                ScanScreen(engine: engine, camera: camera)
            } else {
                Color.clear
            }
        }
        .screenBackground()
        .navigationTitle("Scan")
        .toolbar { NavigationLink("LED Map") { LEDMapView() } }
        .onAppear {
            camera.start()
            if engine == nil { engine = MappingEngine(ideal: ideal, camera: camera, settings: settings) }
        }
        .onDisappear {
            engine?.cancel()
            camera.stop()
        }
    }
}

struct ScanScreen: View {
    @EnvironmentObject var ideal: IdealController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var maps: LEDMapStore
    @ObservedObject var engine: MappingEngine
    @ObservedObject var camera: CameraCapture
    @State private var sectionName = ""
    @State private var shutterIndex = 0
    @State private var colorIndex = 0
    @State private var savedName: String?

    private let shutters: [(String, Double)] = [("1/1000", 1.0 / 1000), ("1/500", 1.0 / 500), ("1/250", 1.0 / 250), ("1/125", 1.0 / 125), ("1/60", 1.0 / 60), ("1/30", 1.0 / 30)]
    private let colors: [(String, RGB)] = [("Verde", .green), ("Bianco", RGB(r: 255, g: 255, b: 255)), ("Rosso", .red), ("Blu", .blue)]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                previewCard
                EngineStatus(engine: engine, onSave: save, savedName: savedName)
                settingsCard
                tipsCard
            }
            .padding()
        }
    }

    private var previewCard: some View {
        Card(title: "Inquadratura", systemImage: "camera.viewfinder") {
            ZStack {
                if camera.authorized == false {
                    Text("Permesso fotocamera negato: abilitalo in Impostazioni › Audi Light Studio.")
                        .font(.caption).foregroundStyle(Theme.danger).padding()
                } else {
                    CameraPreview(session: camera.session)
                    if engine.phase == .done {
                        PointsOverlay(points: engine.points)
                    }
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxHeight: 460)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity)
            if camera.exposureLocked {
                Label("Esposizione bloccata", systemImage: "lock.fill").font(.caption).foregroundStyle(Theme.warning)
            }
            if let e = camera.lastError { Text(e).font(.caption).foregroundStyle(Theme.danger) }
        }
    }

    private var settingsCard: some View {
        Card(title: "Scansione", systemImage: "slider.horizontal.3") {
            TextField("Nome sezione (es. pavimento, lato sinistro)", text: $sectionName)
                .textFieldStyle(.roundedBorder)
            Picker("Tempo di scatto", selection: $shutterIndex) {
                ForEach(shutters.indices, id: \.self) { Text(shutters[$0].0).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Colore LED", selection: $colorIndex) {
                ForEach(colors.indices, id: \.self) { Text(colors[$0].0).tag($0) }
            }
            .pickerStyle(.segmented)
            let busy = engine.phase.isBusy
            HStack(spacing: 10) {
                Button {
                    savedName = nil
                    engine.run(shutter: shutters[shutterIndex].1, color: colors[colorIndex].1)
                } label: { Label("Avvia mappatura", systemImage: "play.fill") }
                    .buttonStyle(AccentButtonStyle())
                    .enabled(!busy && ideal.canDraw && camera.running)
                if busy {
                    Button("Stop") { engine.cancel() }
                        .buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false))
                        .frame(width: 90)
                }
            }
            Text("\(settings.ledCount) LED → \(engine.plannedFrames) fotogrammi (riferimenti + bit e complementari). Circa 3 s ciascuno.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
            if !ideal.canDraw { QuickConnectView(compact: true) }
        }
    }

    private var tipsCard: some View {
        Card(title: "Per un buon risultato", systemImage: "lightbulb") {
            VStack(alignment: .leading, spacing: 6) {
                Text("• Telefono fermo per tutta la sequenza (appoggialo o usa un supporto).")
                Text("• Abbassa le luci ed evita superfici lucide: le piastrelle riflettono i LED. Meglio inquadrare dall'alto che di traverso.")
                Text("• Inquadra il tratto di striscia da vicino: i LED devono restare separati nell'immagine.")
                Text("• Se i LED appaiono bruciati (bianchi pieni) usa un tempo più breve; se non si vedono, più lungo.")
                Text("• Con il cablaggio a Y ogni indice compare due volte se inquadri entrambe le file.")
            }
            .font(.caption)
        }
    }

    private func save() {
        let name = sectionName.trimmingCharacters(in: .whitespaces)
        let s = maps.add(name: name, ledCount: settings.ledCount, imageSize: engine.imageSize,
                         points: engine.points, snapshot: engine.snapshot)
        savedName = s.name
    }
}

struct EngineStatus: View {
    @ObservedObject var engine: MappingEngine
    var onSave: () -> Void
    var savedName: String?

    var body: some View {
        Card(title: "Stato", systemImage: "waveform.path.ecg") {
            switch engine.phase {
            case .idle:
                Text("Pronto.").font(.subheadline)
            case .preparing:
                Label("Blocco esposizione…", systemImage: "hourglass").font(.subheadline)
            case let .running(step, total, label):
                ProgressView(value: Double(step - 1), total: Double(total)).tint(Theme.accent)
                Text("Fotogramma \(step)/\(total): \(label)").font(Theme.monoSmall)
            case .decoding:
                Label("Analisi dei fotogrammi…", systemImage: "cpu").font(.subheadline)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(Theme.danger)
            case .done:
                if let s = engine.summary {
                    stat("Punti trovati", "\(s.points)")
                    stat("Decodificati", "\(s.decoded)")
                    stat("Indici distinti", "\(s.uniqueIndices) / \(engine.settings.ledCount)")
                    stat("Indici visti due volte (Y)", "\(s.duplicatedIndices)")
                    if s.conflicts > 0 { stat("Indici in conflitto (>2)", "\(s.conflicts)") }
                    if !s.missing.isEmpty { stat("Mancanti", IndexRanges.text(s.missing)) }
                    stat("Durata", String(format: "%.0f s", engine.elapsed))
                }
                Text("Cerchi cyan = decodificati, rossi = codice non valido o incerto (correggibili in LED Map).")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                if let savedName {
                    Label("Salvata come \"\(savedName)\"", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.subheadline)
                } else {
                    Button { onSave() } label: { Label("Salva mappa", systemImage: "square.and.arrow.down") }
                        .buttonStyle(AccentButtonStyle())
                }
            }
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(v).font(Theme.mono).multilineTextAlignment(.trailing)
        }
    }
}
