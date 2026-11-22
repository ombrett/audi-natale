import SwiftUI

/// Studio Effetti: programma a livelli calcolato sulle coordinate dei LED, anteprima 3D,
/// modalità Live, selezione e pittura di LED singoli, gruppi e gradienti.
struct EffectsStudioView: View {
    @EnvironmentObject var hub: ControllerHub
    @EnvironmentObject var carMaps: CarMapStore
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var library: EffectLibrary
    @EnvironmentObject var model: CarModelStore

    @State private var program = EffectProgram(name: "Nuovo effetto", layers: [EffectLayer()])
    @State private var camera: CameraPreset = .iso
    @State private var camToken = 0
    @State private var selecting = false
    @State private var selection: Set<LEDKey> = []
    @State private var paintColor = Color(red: 1, green: 0.2, blue: 0.2)
    @State private var gradA = Color(red: 0, green: 0.86, blue: 0.96)
    @State private var gradB = Color(red: 0.6, green: 0.2, blue: 1)
    @State private var gradAxis: EffectAxis = .frontBack
    @State private var savedNote: String?
    @State private var loadedFromPlayer = false

    var body: some View {
        let built = SceneContentBuilder.build(map: carMaps.active, colors: player.colors, coloring: .effect, filter: .all,
                                              controllers: hub.controllers, highlight: selecting ? selection : [], model: model)
        ScrollView {
            VStack(spacing: 14) {
                Card {
                    CarSceneView(content: built.0, camera: camera, cameraToken: camToken) { idx in
                        guard selecting, let idx, built.1.indices.contains(idx),
                              let led = carMaps.active?.leds.first(where: { $0.id == built.1[idx] }) else { return }
                        if selection.contains(led.key) { selection.remove(led.key) } else { selection.insert(led.key) }
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    HStack {
                        ForEach([CameraPreset.iso, .left, .front, .top]) { p in
                            Button(p.label) { camera = p; camToken += 1 }
                                .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Theme.surfaceHigh))
                        }
                        Spacer()
                        if carMaps.active?.isDemo == true { Badge(text: "DEMO", color: Theme.warning) }
                    }
                    if carMaps.active == nil {
                        Text("Serve una mappa (Scansione o mappa dimostrativa nella Mappa 3D) per calcolare gli effetti sulle posizioni dei LED.")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
                transportCard
                ForEach($program.layers) { $layer in
                    LayerCard(layer: $layer, selectionCount: selection.count) {
                        let id = layer.id
                        DispatchQueue.main.async { program.layers.removeAll { $0.id == id } }
                    } useSelection: {
                        layer.keys = selection.isEmpty ? nil : Array(selection)
                    }
                }
                Button { program.layers.append(EffectLayer()) } label: { Label("Aggiungi livello", systemImage: "plus.square.on.square") }
                    .buttonStyle(AccentButtonStyle(filled: false))
                paintCard
                NavigationLink { AnimationsView() } label: {
                    Label("Effetti interni della centralina (singola centralina, Bluetooth Lab)", systemImage: "cpu").font(.subheadline)
                }
                .padding(.bottom, 8)
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Studio Effetti")
        .onAppear {
            player.setMap(carMaps.active)
            if !loadedFromPlayer, let p = player.program { program = p }
            loadedFromPlayer = true
            player.update(program)
        }
        .onChange(of: program) { p in player.update(p) }
    }

    // MARK: Card

    private var transportCard: some View {
        Card(title: "Riproduzione", systemImage: "play.rectangle") {
            TextField("Nome effetto", text: $program.name).textFieldStyle(.roundedBorder)
            Picker("Modalità", selection: $player.mode) {
                ForEach(EffectPlayer.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                if player.isPlaying {
                    Button { player.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(AccentButtonStyle(color: Theme.danger))
                } else {
                    Button { player.play(program) } label: { Label("Riproduci", systemImage: "play.fill") }
                        .buttonStyle(AccentButtonStyle())
                        .enabled(carMaps.active != nil)
                }
                Button { library.save(program); savedNote = "Salvato in Preset" } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(AccentButtonStyle(filled: false)).frame(width: 64)
            }
            if player.mode == .live {
                VStack(alignment: .leading, spacing: 4) {
                    if let fps = player.liveFPS, let dt = player.lastFrameSeconds {
                        Text(String(format: "Live: %.2f fotogrammi/s · ultimo fotogramma %.1f s", fps, dt)).font(Theme.monoSmall)
                    }
                    if let s = player.liveStatus { Text(s).font(.caption).foregroundStyle(Theme.warning) }
                    Text("Ogni fotogramma viene inviato a tutte le centraline e confermato LED per LED (circa 72 comandi/s ciascuna, misurato). Gli effetti che cambiano tutti i LED a ogni fotogramma scorrono a scatti: è il limite del protocollo, non dell'app. Il modello mostra esattamente il fotogramma inviato.")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                    if !player.liveReady { Text("Nessuna centralina pronta.").font(.caption).foregroundStyle(Theme.danger) }
                }
            } else {
                Text("Anteprima: nessun comando Bluetooth, il modello mostra l'effetto a 30 fotogrammi/s.")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            if let savedNote { Text(savedNote).font(.caption).foregroundStyle(Theme.ok) }
        }
    }

    private var paintCard: some View {
        Card(title: "Selezione e pittura", systemImage: "paintbrush") {
            Toggle("Seleziona toccando i LED nel modello", isOn: $selecting).font(.subheadline)
            HStack(spacing: 8) {
                Menu {
                    Button("Tutti") { selection = Set(carMaps.active?.leds.map { $0.key } ?? []) }
                    ForEach(hub.controllers) { c in
                        Button(c.name) { selection = Set(carMaps.active?.leds.filter { $0.key.controller == c.id }.map { $0.key } ?? []) }
                    }
                    ForEach(CarZone.allCases.filter { $0 != .all }) { z in
                        Button(z.label) {
                            guard let m = carMaps.active else { return }
                            selection = Set(m.leds.filter { ZoneClassifier.zone(of: m.carPosition($0)) == z }.map { $0.key })
                        }
                    }
                } label: { Label("Seleziona gruppo", systemImage: "rectangle.dashed") }
                Spacer()
                Text("\(selection.count) pixel").font(Theme.monoSmall)
                Button("Svuota") { selection = [] }.font(.caption)
            }
            HStack {
                ColorPicker("Colore", selection: $paintColor, supportsOpacity: false)
                Button("Dipingi") {
                    let c = RGB(paintColor)
                    for k in selection { program.paint[k] = c }
                }
                .buttonStyle(AccentButtonStyle(filled: false)).frame(width: 110)
                .enabled(!selection.isEmpty)
            }
            HStack {
                ColorPicker("Da", selection: $gradA, supportsOpacity: false).labelsHidden()
                ColorPicker("A", selection: $gradB, supportsOpacity: false).labelsHidden()
                Picker("Asse", selection: $gradAxis) {
                    ForEach(EffectAxis.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.menu)
                Spacer()
                Button("Gradiente") { applyGradient() }
                    .buttonStyle(AccentButtonStyle(filled: false)).frame(width: 110)
                    .enabled(!selection.isEmpty && carMaps.active != nil)
            }
            HStack {
                Text("\(program.paint.count) pixel dipinti (sopra i livelli)").font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Cancella pittura") { program.paint = [:] }.font(.caption).disabled(program.paint.isEmpty)
            }
            Text("Con i LED a Y, dipingere un pixel colora entrambe le posizioni fisiche.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private func applyGradient() {
        guard let m = carMaps.active else { return }
        let ctx = EffectContext(points: m.effectPoints)
        for (k, c) in EffectEngine.gradient(keys: selection, context: ctx, axis: gradAxis, from: RGB(gradA), to: RGB(gradB)) {
            program.paint[k] = c
        }
    }
}

struct LayerCard: View {
    @Binding var layer: EffectLayer
    var selectionCount: Int
    var onDelete: () -> Void
    var useSelection: () -> Void

    var body: some View {
        Card(title: layer.params.kind.label, systemImage: layer.params.kind.icon) {
            HStack {
                Toggle("Attivo", isOn: $layer.enabled).labelsHidden()
                Picker("Zona", selection: $layer.zone) {
                    ForEach(CarZone.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.menu)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            }
            Picker("Effetto", selection: $layer.params.kind) {
                ForEach(EffectKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }.pickerStyle(.menu)
            HStack {
                ColorPicker("Colore 1", selection: colorBinding(0), supportsOpacity: false)
                ColorPicker("Colore 2", selection: colorBinding(1), supportsOpacity: false)
            }
            .font(.subheadline)
            slider("Velocità", $layer.params.speed, 0.02...3, format: "%.2f cicli/s")
            slider("Intensità", $layer.params.intensity, 0...1, format: "%.0f%%", scale: 100)
            slider("Larghezza", $layer.params.width, 0.05...1, format: "%.2f")
            HStack {
                Picker("Direzione", selection: $layer.params.axis) {
                    ForEach(EffectAxis.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.menu)
                Toggle("Inverti", isOn: $layer.params.reversed).font(.subheadline)
            }
            HStack {
                Text(layer.keys.map { "Solo \($0.count) pixel selezionati" } ?? "Tutti i pixel della zona").font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(layer.keys == nil ? "Usa selezione (\(selectionCount))" : "Tutta la zona") {
                    if layer.keys == nil { useSelection() } else { layer.keys = nil }
                }
                .font(.caption)
                .disabled(layer.keys == nil && selectionCount == 0)
            }
        }
        .opacity(layer.enabled ? 1 : 0.55)
    }

    private func colorBinding(_ i: Int) -> Binding<Color> {
        Binding(get: {
            Color(rgb: layer.params.colors.indices.contains(i) ? layer.params.colors[i] : .black)
        }, set: { c in
            while layer.params.colors.count <= i { layer.params.colors.append(.black) }
            layer.params.colors[i] = RGB(c)
        })
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String, scale: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale)).font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
            }
            Slider(value: value, in: range)
        }
    }
}
