import SwiftUI

/// Animazioni calcolate dalla centralina (fluide, nessuna trasmissione continua).
struct AnimationsView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case twoColor = "Due colori"
        case scene = "Multicolore"
        var id: String { rawValue }
    }

    @EnvironmentObject var ideal: IdealController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BLEManager

    @State private var kind: Kind = .twoColor
    @State private var sglsMode = 3
    @State private var multEffect = 9
    @State private var speed = 60.0
    @State private var brightness = 60.0
    @State private var reversed = false
    @State private var foreground = Color(red: 0, green: 0.86, blue: 0.96)
    @State private var background = Color.black
    @State private var sceneColors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue]
    @State private var colorCount = 4
    @State private var result: String?
    @State private var busy = false
    @State private var confirm: (title: String, message: String, run: () -> Void)?
    @State private var showConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Tipo", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if kind == .twoColor { twoColorCard } else { sceneCard }
                commonCard
                resultCard
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Animations")
        .alert(confirm?.title ?? "", isPresented: $showConfirm) {
            Button("Invia", role: .destructive) { confirm?.run() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(confirm?.message ?? "")
        }
    }

    // MARK: Card

    private var twoColorCard: some View {
        Card(title: "Effetto a due colori (SGLS)", systemImage: "wand.and.rays") {
            Picker("Effetto", selection: $sglsMode) {
                ForEach(0..<IdealEffects.sglsNames.count, id: \.self) { i in
                    Text("\(i) · \(IdealEffects.sglsNames[i])").tag(i)
                }
            }
            .pickerStyle(.menu)
            statusBadge(captured: IdealEffects.sglsCaptured.contains(sglsMode), tag: "SGLS#\(sglsMode)")
            ColorPicker("Primo piano", selection: $foreground, supportsOpacity: false)
            ColorPicker("Sfondo", selection: $background, supportsOpacity: false)
        }
    }

    private var sceneCard: some View {
        Card(title: "Scena multicolore (MULT)", systemImage: "rainbow") {
            Picker("Effetto", selection: $multEffect) {
                ForEach(0..<IdealEffects.multNames.count, id: \.self) { i in
                    Text("\(i) · \(IdealEffects.multNames[i])").tag(i)
                }
            }
            .pickerStyle(.menu)
            statusBadge(captured: IdealEffects.multCaptured.contains(multEffect), tag: "MULT#\(multEffect)")
            Stepper("Colori: \(colorCount)", value: $colorCount, in: 1...IdealEffects.maxSceneColors)
            HStack(spacing: 8) {
                ForEach(0..<colorCount, id: \.self) { i in
                    ColorPicker("", selection: $sceneColors[i], supportsOpacity: false).labelsHidden()
                }
            }
            Text("Massimo \(IdealEffects.maxSceneColors) colori: il controller accetta pacchetti da 20 byte. Il formato con frame corti non è ancora catturato: il primo invio è sperimentale e si ferma se manca la conferma MULTOK.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private var commonCard: some View {
        Card(title: "Parametri", systemImage: "dial.medium") {
            VStack(alignment: .leading) {
                Text("Velocità: \(Int(speed))").font(.subheadline)
                Slider(value: $speed, in: 0...100, step: 1)
            }
            VStack(alignment: .leading) {
                Text("Luminosità: \(Int(brightness))%").font(.subheadline)
                Slider(value: $brightness, in: 0...100, step: 1)
            }
            Toggle("Direzione invertita", isOn: $reversed).font(.subheadline)
            Button {
                play()
            } label: { Label(busy ? "Invio…" : "Avvia sulla centralina", systemImage: "play.fill") }
                .buttonStyle(AccentButtonStyle())
                .enabled(ideal.canDraw && !busy)
            if !ideal.canDraw {
                Text("Collega il controller e completa la verifica nel Bluetooth Lab.").font(.caption).foregroundStyle(Theme.warning)
            }
            Text("Con il cablaggio a Y l'effetto scorre uguale su entrambe le file. L'effetto resta attivo anche a telefono spento.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private var resultCard: some View {
        Card(title: "Esito", systemImage: "checkmark.message") {
            Text(result ?? "—").font(.subheadline)
        }
    }

    @ViewBuilder
    private func statusBadge(captured: Bool, tag: String) -> some View {
        if ideal.confirmedTags.contains(tag) {
            Badge(text: "VERIFICATO SU QUESTO CONTROLLER", color: Theme.ok)
        } else if captured {
            Badge(text: "CATTURATO SU ALTRO CONTROLLER", color: Theme.accent)
        } else {
            Badge(text: "SPERIMENTALE (DAL FIRMWARE)", color: Theme.warning)
        }
    }

    // MARK: Azioni

    private func play() {
        let sp = Int(self.speed), br = Int(self.brightness)
        switch kind {
        case .twoColor:
            let mode = sglsMode
            let fg = RGB(foreground), bg = RGB(background)
            let run = {
                busy = true
                ideal.playEffect(mode: mode, reversed: reversed, speed: sp, foreground: fg, background: bg, brightness: br) { msg in
                    busy = false
                    result = msg
                }
            }
            if ideal.confirmedTags.contains("SGLS#\(mode)") { run(); return }
            let why = IdealEffects.sglsCaptured.contains(mode)
                ? "Formato catturato dall'app originale su un altro controller ISP."
                : "Modalità ricavata dal firmware TR2309, mai catturata. Valori nei limiti sicuri (0–9)."
            ask("Effetto \(mode) · \(IdealEffects.sglsNames[mode])", why, run)
        case .scene:
            let effect = multEffect
            let colors = sceneColors.prefix(colorCount).map { RGB($0) }
            let run = {
                busy = true
                ideal.playScene(effect: effect, reversed: reversed, speed: sp, colors: Array(colors), brightness: br) { msg in
                    busy = false
                    result = msg
                }
            }
            if ideal.confirmedTags.contains("MULT#\(effect)") { run(); return }
            ask("Scena \(effect) · \(IdealEffects.multNames[effect])",
                "Intestazione MULT catturata dall'app originale; frame colori da 20 byte (MTU 23) non ancora catturato. Effetto e numero colori nei limiti sicuri.", run)
        }
    }

    private func ask(_ title: String, _ message: String, _ run: @escaping () -> Void) {
        confirm = (title, message + "\n\nNon ancora confermato su questo controller: inviare?", run)
        showConfirm = true
    }
}
