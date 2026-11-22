import SwiftUI

/// Le 60 animazioni pre-calcolate sul layout A1 da 1600 LED: anteprima 3D e Live.
struct ClipLibraryView: View {
    @EnvironmentObject var clips: ClipLibrary
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var hub: ControllerHub
    @EnvironmentObject var carMaps: CarMapStore
    @EnvironmentObject var model: CarModelStore

    @State private var camera: CameraPreset = .iso
    @State private var camToken = 0
    @State private var search = ""
    @State private var useTint = false
    @State private var tint = Color(red: 0, green: 0.85, blue: 1)

    var body: some View {
        let built = SceneContentBuilder.build(map: carMaps.active, colors: player.colors, coloring: .effect, filter: .all,
                                              controllers: hub.controllers, highlight: [], model: model)
        ScrollView {
            VStack(spacing: 14) {
                Card {
                    CarSceneView(content: built.0, camera: camera, cameraToken: camToken) { _ in }
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    HStack {
                        ForEach([CameraPreset.iso, .left, .rear, .top]) { p in
                            Button(p.label) { camera = p; camToken += 1 }
                                .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Theme.surfaceHigh))
                        }
                        Spacer()
                        if carMaps.active?.isDesign != true { Badge(text: "SERVE IL LAYOUT A1", color: Theme.warning) }
                    }
                    if carMaps.active?.isDesign != true {
                        Text("Le animazioni sono calcolate sul layout di progetto: caricalo da Mappa 3D → menu mappa → \"Carica layout A1 di progetto\" per vederle al posto giusto.")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
                controlsCard
                listCard
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("60 animazioni A1")
        .onAppear { clips.loadIfNeeded() }
        .onChange(of: useTint) { _ in applyTint() }
        .onChange(of: tint) { _ in applyTint() }
    }

    private var controlsCard: some View {
        Card(title: player.clip?.name ?? "Riproduzione", systemImage: "film.stack") {
            Picker("Modalità", selection: $player.mode) {
                ForEach(EffectPlayer.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            slider("Velocità", value: $player.clipSettings.speed, range: 0.5...2, format: "%.2f×")
            slider("Intensità", value: $player.clipSettings.intensity, range: 0...1, format: "%.0f%%", scale: 100)
            Toggle("Colore unico", isOn: $useTint)
            if useTint { ColorPicker("Colore", selection: $tint, supportsOpacity: false) }
            if player.isPlaying && player.clip != nil {
                Button { player.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(AccentButtonStyle(color: Theme.danger))
            }
            if player.mode == .live {
                if let fps = player.liveFPS { Text(String(format: "Live: %.2f fotogrammi/s", fps)).font(Theme.monoSmall) }
                if let s = player.liveStatus { Text(s).font(.caption).foregroundStyle(Theme.warning) }
                Text("Le animazioni sono a 24 fotogrammi/s; dal vivo ogni fotogramma viene inviato quando le centraline hanno confermato il precedente, saltando quelli intermedi. Con circa 72 comandi/s per centralina, gli effetti che cambiano tutti i LED scorrono a scatti.")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Anteprima: nessun comando Bluetooth.").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            if hub.controllers.count < (clips.pack?.controllerIDs.count ?? 4) {
                Text("Il pacchetto usa 4 pacchi (A–D): A va alla 1ª centralina della lista, B alla 2ª… Quelli senza centralina non si vedono.")
                    .font(.caption2).foregroundStyle(Theme.warning)
            }
        }
    }

    private var listCard: some View {
        Card(title: "Animazioni", systemImage: "sparkles.rectangle.stack") {
            if clips.isLoading { ProgressView("Caricamento…") }
            if let e = clips.error { Text(e).font(.caption).foregroundStyle(Theme.danger) }
            if let pack = clips.pack {
                TextField("Cerca", text: $search).textFieldStyle(.roundedBorder)
                ForEach(pack.presets.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { p in
                    Button { player.play(clip: p, in: pack) } label: {
                        HStack {
                            Image(systemName: player.clip?.id == p.id && player.isPlaying ? "speaker.wave.2.fill" : "play.circle.fill")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                Text(String(format: "%.1f s · %@", p.duration, p.loop ? "in loop" : "una volta, resta sull'ultimo fotogramma"))
                                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, scale: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.subheadline); Spacer(); Text(String(format: format, value.wrappedValue * scale)).font(Theme.monoSmall) }
            Slider(value: value, in: range)
        }
    }

    private func applyTint() {
        player.clipSettings.tint = useTint ? RGB(tint) : nil
    }
}
