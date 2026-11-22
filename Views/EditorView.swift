import SwiftUI
import UIKit

/// Editor della striscia (Milestone 2): un colore per indice, invio con DOOD verificati.
/// Disposizione per indice (non ancora la forma reale dell'auto: arriverà con la mappatura).
struct EditorView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case brush = "Pennello", eraser = "Gomma", fill = "Riempi"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .brush: return "paintbrush.pointed.fill"
            case .eraser: return "eraser.fill"
            case .fill: return "drop.fill"
            }
        }
    }

    @EnvironmentObject var ideal: IdealController
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var presets: PresetStore
    @EnvironmentObject var maps: LEDMapStore

    enum Layout: String, CaseIterable, Identifiable {
        case grid = "Griglia", map = "Mappa"
        var id: String { rawValue }
    }

    @State private var pixels: [RGB] = []
    @State private var tool: Tool = .brush
    @State private var color: Color = Color(red: 0, green: 0.86, blue: 0.96)
    @State private var live = false
    @State private var showSave = false
    @State private var presetName = ""
    @State private var showPresets = false
    @State private var lastPainted: Int?
    @State private var animation: DIYMode = .static
    @State private var animSpeed = 60.0
    @State private var askAnimation = false
    @State private var layout: Layout = .grid
    @State private var sectionID: UUID?
    @State private var mapImage: UIImage?
    @State private var textValue = ""
    @State private var textSize = 0.45
    @State private var textRotated = false
    @State private var textClearsBackground = true

    private let columns = 20

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.accent)
                        Text("Cablaggio a Y: ogni indice accende lo stesso LED su entrambe le file.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                canvasCard
                toolsCard
                if layout == .map && section != nil { textCard }
                sendCard
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Editor")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                NavigationLink { AnimationsView() } label: { Image(systemName: "sparkles") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showSave = true } label: { Label("Salva preset", systemImage: "square.and.arrow.down") }
                    Button { showPresets = true } label: { Label("Apri preset", systemImage: "folder") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear(perform: resize)
        .onChange(of: settings.ledCount) { _ in resize() }
        .alert("Salva preset", isPresented: $showSave) {
            TextField("Nome", text: $presetName)
            Button("Salva") { presets.save(name: presetName, pixels: pixels); presetName = "" }
            Button("Annulla", role: .cancel) {}
        }
        .sheet(isPresented: $showPresets) { presetSheet }
        .alert("Animazione \(animation.label)", isPresented: $askAnimation) {
            Button("Invia") { ideal.apply(target: pixels, mode: animation, speed: Int(animSpeed)) }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("La modalità \(animation.label.lowercased()) dei pixel DIY è ricavata dal firmware TR2309 e non è mai stata catturata. Velocità nei limiti sicuri (1–100). Inviare?")
        }
    }

    // MARK: Tela

    private var section: LEDMapSection? {
        maps.sections.first { $0.id == sectionID } ?? maps.sections.first
    }

    private var canvasCard: some View {
        Card(title: "Disegno · \(pixels.count) indici", systemImage: "square.grid.4x3.fill") {
            if !maps.sections.isEmpty {
                Picker("Vista", selection: $layout) {
                    ForEach(Layout.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: animation == .static)) { tl in
                let level = MapPainter.previewLevel(mode: animation, speed: Int(animSpeed),
                                                    time: tl.date.timeIntervalSinceReferenceDate)
                if layout == .map, let s = section {
                    mapCanvas(s, level: level)
                } else {
                    gridCanvas(level: level)
                }
            }
            HStack {
                Text(layout == .map ? "Tocca o trascina sui LED della mappa." : "Indice 0 in alto a sinistra, poi per righe da \(columns).")
                Spacer()
                if let i = lastPainted { Text("#\(i)").font(Theme.mono) }
            }
            .font(.caption2).foregroundStyle(Theme.textSecondary)
            Text(animation == .static ? "Bordo arancione = diverso da quanto confermato dal controller."
                                      : "Anteprima \(animation.label.lowercased()) indicativa: i tempi reali li decide la centralina.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .onChange(of: sectionID) { _ in loadMapImage() }
        .onChange(of: layout) { _ in loadMapImage() }
        .onAppear(perform: loadMapImage)
    }

    private func gridCanvas(level: Double) -> some View {
        GeometryReader { geo in
            let cell = geo.size.width / CGFloat(columns)
            ZStack(alignment: .topLeading) {
                ForEach(pixels.indices, id: \.self) { i in
                    let c = pixels[i]
                    Circle()
                        .fill(c == .black ? Theme.surfaceHigh : Color(rgb: c).opacity(level))
                        .overlay(Circle().stroke(isSent(i) ? Color.clear : Theme.warning.opacity(0.7), lineWidth: 1))
                        .frame(width: cell * 0.74, height: cell * 0.74)
                        .position(x: (CGFloat(i % columns) + 0.5) * cell, y: (CGFloat(i / columns) + 0.5) * cell)
                }
            }
            .drawingGroup()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in paint(at: v.location, cell: cell) }
                .onEnded { _ in strokeEnded() })
        }
        .aspectRatio(CGFloat(columns) / CGFloat(max(rows, 1)), contentMode: .fit)
    }

    private func mapCanvas(_ s: LEDMapSection, level: Double) -> some View {
        GeometryReader { geo in
            ZStack {
                if let img = mapImage {
                    Image(uiImage: img).resizable().scaledToFit().opacity(0.25)
                } else {
                    Color.black
                }
                ForEach(s.points.filter { $0.index != nil }) { p in
                    let i = p.index ?? 0
                    let c = pixels.indices.contains(i) ? pixels[i] : .black
                    Circle()
                        .fill(c == .black ? Theme.surfaceHigh : Color(rgb: c).opacity(level))
                        .frame(width: 9, height: 9)
                        .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in paintMap(v.location, size: geo.size, section: s) }
                .onEnded { _ in strokeEnded() })
        }
        .aspectRatio(s.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var textCard: some View {
        Card(title: "Testo sulla mappa", systemImage: "textformat") {
            if maps.sections.count > 1 {
                Picker("Sezione", selection: Binding(get: { section?.id }, set: { sectionID = $0 })) {
                    ForEach(maps.sections) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            TextField("Testo", text: $textValue).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading) {
                Text("Altezza: \(Int(textSize * 100))%").font(.subheadline)
                Slider(value: $textSize, in: 0.1...0.9)
            }
            Toggle("Ruota di 90° (foto fatta in orizzontale)", isOn: $textRotated).font(.subheadline)
            Toggle("Spegni i LED fuori dal testo", isOn: $textClearsBackground).font(.subheadline)
            Button("Applica testo") { applyText() }
                .buttonStyle(AccentButtonStyle(filled: false))
                .enabled(!textValue.isEmpty && section != nil)
            Text("Il testo è leggibile solo dove i LED mappati sono abbastanza fitti: con 10 LED/m su una linea si vedono soprattutto forme e lettere grandi.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private var toolsCard: some View {
        Card(title: "Strumenti", systemImage: "wand.and.stars") {
            Picker("Strumento", selection: $tool) {
                ForEach(Tool.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                ColorPicker("Colore", selection: $color, supportsOpacity: false)
                    .font(.subheadline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(swatches, id: \.self) { s in
                        Circle().fill(Color(rgb: s)).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.white.opacity(0.3)))
                            .onTapGesture { color = Color(rgb: s) }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Pulisci") { setAll(.black) }
                Button("Arcobaleno") { rainbow() }
                Button("Gradiente") { gradient() }
            }
            .buttonStyle(AccentButtonStyle(filled: false))
            Stepper("Luminosità DIY: \(settings.diyBrightness)%", value: $settings.diyBrightness, in: 1...100, step: 5)
                .font(.subheadline)
            Picker("Animazione", selection: $animation) {
                ForEach([DIYMode.static, .breathe, .flash]) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if animation != .static {
                VStack(alignment: .leading) {
                    Text("Velocità animazione: \(Int(animSpeed))").font(.subheadline)
                    Slider(value: $animSpeed, in: 1...100, step: 1)
                }
                Text("Il controller anima da solo ogni LED acceso; stessa velocità = LED sincronizzati.")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var sendCard: some View {
        Card(title: "Invio", systemImage: "paperplane") {
            if !ideal.canDraw { QuickConnectView(compact: true) }
            Toggle("Live: invia a ogni tratto", isOn: $live).font(.subheadline)
            Stepper("Finestra di invio: \(settings.sendWindow)", value: $settings.sendWindow, in: 1...8)
                .font(.subheadline)
            Text("Comandi mandati prima di aspettare le conferme. Verificato su ISP-B0717F: 6 = ~72 cmd/s senza ritentativi; 8 non è più veloce.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Button {
                    sendDrawing()
                } label: { Label("Invia al controller", systemImage: "paperplane.fill") }
                    .buttonStyle(AccentButtonStyle())
                    .enabled(ideal.canDraw)
                if ideal.transfer?.isRunning == true {
                    Button("Stop") { ideal.cancelTransfer() }
                        .buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false))
                        .frame(width: 90)
                }
            }
            if let t = ideal.transfer {
                ProgressView(value: Double(t.done), total: Double(max(t.total, 1)))
                    .tint(t.error == nil ? Theme.accent : Theme.danger)
                HStack {
                    Text("\(t.done)/\(t.total) comandi")
                    Spacer()
                    if let r = t.opsPerSecond { Text(String(format: "%.1f cmd/s", r)) }
                    if t.retries > 0 { Text("· \(t.retries) ritentativi") }
                }
                .font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                if let e = t.error { Text(e).font(.caption).foregroundStyle(Theme.danger) }
            }
            Button("Esci da DIY mantenendo il disegno") { ideal.exitDIY(keepDrawing: true) }
                .buttonStyle(AccentButtonStyle(filled: false))
                .enabled(ideal.diyActive && ideal.transfer?.isRunning != true)
            Text("Usa solo DOOD verificato (un comando per pixel o riempimento, ognuno confermato da DOODOK). L'invio in blocco DOOT resta disattivato finché non è catturato con MTU 23.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private var presetSheet: some View {
        NavigationStack {
            List {
                if presets.presets.isEmpty {
                    Text("Nessun preset salvato.").foregroundStyle(Theme.textSecondary)
                }
                ForEach(presets.presets) { p in
                    Button {
                        load(p)
                        showPresets = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name)
                            HStack(spacing: 1) {
                                ForEach(Array(stride(from: 0, to: p.pixels.count, by: max(p.pixels.count / 40, 1))), id: \.self) { i in
                                    Rectangle().fill(Color(rgb: p.pixels[i])).frame(height: 8)
                                }
                            }
                        }
                    }
                }
                .onDelete { idx in idx.map { presets.presets[$0] }.forEach(presets.delete) }
            }
            .navigationTitle("Preset")
            .toolbar { Button("Chiudi") { showPresets = false } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Logica

    private var rows: Int { (pixels.count + columns - 1) / columns }

    private var swatches: [RGB] {
        [.red, RGB(r: 255, g: 120, b: 0), RGB(r: 255, g: 220, b: 0), .green, RGB(r: 0, g: 220, b: 245), .blue,
         RGB(r: 150, g: 0, b: 255), RGB(r: 255, g: 0, b: 160), RGB(r: 255, g: 255, b: 255)]
    }

    private func isSent(_ i: Int) -> Bool {
        guard let c = ideal.canvas, c.indices.contains(i) else { return pixels[i] == .black }
        return c[i] == pixels[i]
    }

    private func resize() {
        let n = min(max(settings.ledCount, 1), IdealProtocol.maxSafeLEDs)
        if pixels.count != n {
            pixels = Array(pixels.prefix(n)) + [RGB](repeating: .black, count: max(0, n - pixels.count))
        }
    }

    private func paint(at p: CGPoint, cell: CGFloat) {
        guard cell > 0, p.x >= 0, p.y >= 0 else { return }
        let col = Int(p.x / cell), row = Int(p.y / cell)
        guard col < columns else { return }
        let i = row * columns + col
        guard pixels.indices.contains(i) else { return }
        lastPainted = i
        switch tool {
        case .brush: pixels[i] = RGB(color)
        case .eraser: pixels[i] = .black
        case .fill: setAll(RGB(color))
        }
    }

    private func strokeEnded() {
        lastPainted = nil
        if live { sendDrawing() }
    }

    private func loadMapImage() {
        mapImage = section.flatMap { maps.image(for: $0) }
    }

    private func paintMap(_ loc: CGPoint, size: CGSize, section s: LEDMapSection) {
        if tool == .fill { setAll(RGB(color)); return }
        guard let i = MapPainter.nearestIndex(points: s.points, x: Double(loc.x), y: Double(loc.y),
                                              width: Double(size.width), height: Double(size.height), maxDistance: 24),
              pixels.indices.contains(i) else { return }
        lastPainted = i
        pixels[i] = tool == .eraser ? .black : RGB(color)
    }

    private func applyText() {
        guard let s = section,
              let mask = TextMask(text: textValue, width: max(s.imageWidth, 1), height: max(s.imageHeight, 1),
                                  heightFraction: textSize, rotated: textRotated) else { return }
        pixels = MapPainter.apply(points: s.points, to: pixels, color: RGB(color),
                                  background: textClearsBackground ? .black : nil) { x, y in mask.contains(x: x, y: y) }
        if live { sendDrawing() }
    }

    private func setAll(_ c: RGB) {
        pixels = [RGB](repeating: c, count: pixels.count)
    }

    private func rainbow() {
        let n = pixels.count
        pixels = (0..<n).map { i in RGB(UIColor(hue: CGFloat(i) / CGFloat(n), saturation: 1, brightness: 1, alpha: 1)) }
    }

    private func gradient() {
        let a = RGB(color), b = RGB.black
        let n = max(pixels.count - 1, 1)
        pixels = (0..<pixels.count).map { i -> RGB in
            let t = Double(i) / Double(n)
            func mix(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) * (1 - t) + Double(y) * t).rounded()) }
            return RGB(r: mix(a.r, b.r), g: mix(a.g, b.g), b: mix(a.b, b.b))
        }
    }

    private func load(_ p: DrawingPreset) {
        let n = pixels.count
        pixels = Array(p.pixels.prefix(n)) + [RGB](repeating: .black, count: max(0, n - p.pixels.count))
    }

    private func sendDrawing() {
        guard ideal.canDraw else { return }
        if animation != .static && !ideal.confirmedTags.contains("DOOD#\(animation.rawValue)") && !askAnimation {
            askAnimation = true
            return
        }
        ideal.apply(target: pixels, mode: animation, speed: Int(animSpeed))
    }
}

extension Color {
    init(rgb: RGB) {
        self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

extension RGB {
    init(_ color: Color) {
        self.init(UIColor(color))
    }

    init(_ ui: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: byte(r), g: byte(g), b: byte(b))
    }
}
