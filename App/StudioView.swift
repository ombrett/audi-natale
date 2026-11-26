import SwiftUI

/// Studio: l'A1 grande e ruotabile, preset in riproduzione, anteprima e invio all'auto separati,
/// inspector del LED toccato. Riusa renderer 3D, mappa attiva e motore effetti esistenti.
struct StudioView: View {
    @EnvironmentObject var hub: ControllerHub
    @EnvironmentObject var carMaps: CarMapStore
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var model: CarModelStore
    @EnvironmentObject var ui: AppUIState
    @EnvironmentObject var adaptiveY: AdaptiveYStore

    @State private var axes: [CGVector] = []
    @State private var zoneCache: [UUID: AdaptiveEffects.Zone] = [:]
    @State private var zoneCacheKey = ""
    @State private var showTuning = false

    private var map: CarMap? { carMaps.active }

    var body: some View {
        let inspection = currentInspection
        let built = SceneContentBuilder.build(map: map, colors: player.colors,
                                              coloring: ui.studioMode == .map ? .zone : .effect, filter: .all,
                                              controllers: player.effectiveControllers,
                                              selected: inspection?.ledID, twin: inspection?.twinID,
                                              zones: zoneCache, model: model)
        VStack(spacing: 0) {
            header
            modeTabs
            ZStack(alignment: .bottomTrailing) {
                CarSceneView(content: built.0, camera: ui.camera, cameraToken: ui.cameraToken,
                             onSelect: { idx in
                                 let id = idx.flatMap { built.1.indices.contains($0) ? built.1[$0] : nil }
                                 withAnimation(.easeOut(duration: 0.2)) { ui.studioSelection = id }
                             },
                             onAxes: { axes = $0 })
                    .accessibilityIdentifier("studio-scene")
                AxisGizmo(axes: axes).padding(14)
                cameraMenu.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                if map == nil { emptyState }
            }
            .frame(maxHeight: .infinity)
            if ui.studioMode == .map { Hairline(); zoneLegend }
            Hairline()
            sourceRow
            Hairline()
            if let inspection {
                InspectorPanel(info: inspection, twin: twinRows(inspection), onClose: { withAnimation(.easeOut(duration: 0.2)) { ui.studioSelection = nil } },
                               onZone: { setZone($0, for: inspection.ledID) }, onReset: { resetZone(inspection.ledID) })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            transport
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $ui.showPresetPicker) { PresetPicker() }
        .sheet(isPresented: $showTuning) { TuningSheet().presentationDetents([.height(430)]) }
        .onAppear(perform: refreshZones)
        .onChange(of: carMaps.activeID) { _ in refreshZones() }
        .onChange(of: carMaps.maps.count) { _ in refreshZones() }
    }

    // MARK: Intestazione

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Studio").font(.system(size: 34, weight: .bold))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(linkColor).frame(width: 8, height: 8)
                Text(linkText).font(Theme.monoBody).foregroundStyle(Theme.textSecondary)
            }
            .onTapGesture { ui.section = .controllers }
            .accessibilityIdentifier("studio-link-status")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var linkText: String {
        let total = hub.enabledControllers.count, ready = hub.readyLinks.count
        if total == 0 || ready == 0 { return "Offline" }
        if player.mode == .live && player.isPlaying { return "Live \(ready)/\(total)" }
        return "\(ready)/\(total) collegate"
    }

    private var linkColor: Color {
        let total = hub.enabledControllers.count, ready = hub.readyLinks.count
        if ready == 0 { return Theme.textSecondary }
        return ready == total ? Theme.accent : Theme.warning
    }

    private var modeTabs: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 28) {
                ForEach(AppUIState.StudioMode.allCases) { m in
                    Button { ui.studioMode = m } label: {
                        VStack(spacing: 8) {
                            Text(m.rawValue).font(.system(size: 17, weight: .medium))
                                .foregroundStyle(ui.studioMode == m ? Theme.accent : Theme.textPrimary)
                            Rectangle().fill(ui.studioMode == m ? Theme.accent : .clear).frame(height: 3)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            Hairline()
        }
    }

    private var cameraMenu: some View {
        Menu {
            ForEach(CameraPreset.allCases) { p in
                Button(p.label) { ui.camera = p; ui.cameraToken += 1 }
            }
        } label: {
            Image(systemName: "video").font(.system(size: 14))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.surface.opacity(0.85)))
                .overlay(Circle().stroke(Theme.stroke))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Nessuna mappa attiva").font(.headline)
            Text("Carica il layout di progetto o fai la scansione dalla Mappa 3D.")
                .font(.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Button("Apri Mappa 3D") { ui.section = .map3D }.buttonStyle(AccentButtonStyle(filled: false)).frame(width: 200)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var zoneLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(AdaptiveEffects.Zone.allCases, id: \.self) { z in
                    HStack(spacing: 5) { Circle().fill(ZonePalette.color(z)).frame(width: 7, height: 7); Text(z.label).font(.system(size: 11)) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    // MARK: Origine delle posizioni

    private var sourceRow: some View {
        let src = MapSource(map)
        let addresses = Set(map?.leds.map { $0.key } ?? []).count
        return HStack {
            Text(src.rawValue).foregroundStyle(src == .scan ? Theme.textPrimary : Theme.textSecondary)
            if src == .design { Text("· posizioni previste").font(.caption).foregroundStyle(Theme.textSecondary) }
            if src == .demo { Text("· non è la tua auto").font(.caption).foregroundStyle(Theme.warning) }
            Spacer()
            Text("\(fmt(map?.leds.count ?? 0)) punti · \(fmt(addresses)) indirizzi").font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityIdentifier("studio-source")
    }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "it_IT")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Trasporto

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button {
                    if player.isPlaying { player.pause() }
                    else if player.hasContent { player.resume() }
                    else if let first = AdaptiveEffects.presets.first { player.play(clip: first) }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(map == nil)
                .accessibilityIdentifier("studio-play")
                Button { ui.showPresetPicker = true } label: {
                    HStack(spacing: 4) {
                        Text(presetName).font(.system(size: 17, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .accessibilityIdentifier("studio-preset")
                if let c = player.clip, let a = adaptiveY.analysis(for: c.id) { ScoreChip(score: a.score) }
                ProgressBar(value: progress).frame(minWidth: 50, maxHeight: 4)
                Text(String(format: "%04.1f s", shownTime).replacingOccurrences(of: ".", with: ","))
                    .font(Theme.monoBody).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("studio-playhead")
            }
            HStack(spacing: 10) {
                Button { player.mode = .preview } label: {
                    Label("Anteprima", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .buttonStyle(SegmentStyle(active: player.mode == .preview))
                Button { player.mode = .live } label: {
                    Label("Invia all'auto", systemImage: "antenna.radiowaves.left.and.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(SegmentStyle(active: player.mode == .live))
                .disabled(hub.readyLinks.isEmpty && player.mode != .live)
                .accessibilityIdentifier("studio-live")
                Button { showTuning = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 40) }
                    .buttonStyle(SegmentStyle(active: false))
            }
            liveNote
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var liveNote: some View {
        let total = hub.enabledControllers.count, ready = hub.readyLinks.count
        if player.mode == .live {
            if ready == 0 {
                note("Nessuna centralina pronta: l'auto non riceve nulla. Collega le centraline o torna in Anteprima.", Theme.warning)
            } else if ready < total {
                let missing = hub.orderedLinks.enumerated().filter { $0.element.config.enabled && !$0.element.isReady }
                    .map { "\(controllerLetter($0.offset)) \($0.element.state.label.lowercased())" }.joined(separator: ", ")
                note("Live su \(ready)/\(total): \(missing). Le altre continuano.", Theme.warning)
            } else if let fps = player.liveFPS {
                note(String(format: "Live · %.2f fotogrammi/s inviati", fps), Theme.textSecondary)
            }
            if let s = player.liveStatus { note(s, Theme.danger) }
        } else if hub.readyLinks.isEmpty {
            note(total == 0 ? "Offline: anteprima sul modello, nessun comando Bluetooth." : "Offline · 0/\(total) collegate: anteprima sul modello.", Theme.textSecondary)
        }
    }

    private func note(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption).foregroundStyle(c).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presetName: String {
        if let c = player.clip { return c.name }
        if let pl = player.playlist { return "Playlist · \(pl.name)" }
        if let p = player.program { return p.name }
        return "Scegli un preset"
    }

    /// Tempo mostrato: dentro la durata del preset (i preset in loop ripartono, gli altri restano alla fine).
    private var shownTime: Double {
        guard let c = player.clip else { return player.playhead }
        return AdaptiveEffects.Engine.phase(c, elapsed: player.playhead) * c.duration
    }

    private var progress: Double {
        guard let d = player.duration, d > 0 else { return 0 }
        let u = AdaptiveEffects.Engine.phase(player.clip!, elapsed: player.playhead)
        return d > 0 ? u : 0
    }

    // MARK: Inspector e zone

    /// Colori ideali delle copie (ordine dei punti in mappa) e colore inviato, per l'inspector.
    private func twinRows(_ info: LEDInspection) -> InspectorPanel.Twin? {
        guard let map, let t = player.twinInfo(info.key) else { return nil }
        let copies = map.leds.filter { $0.key == info.key }
        guard copies.count == t.ideal.count, copies.count > 1 else { return nil }
        let mine = copies.firstIndex { $0.id == info.ledID } ?? 0
        let other = copies.indices.first { $0 != mine } ?? 0
        return InspectorPanel.Twin(touched: t.ideal[mine], twin: t.ideal[other], strategy: t.strategy, conflict: t.conflict)
    }

    private var currentInspection: LEDInspection? {
        guard let id = ui.studioSelection, let map else { return nil }
        return LEDInspection.make(map: map, ledID: id, controllers: player.effectiveControllers, colors: player.colors,
                                  design: ProjectLayout.bundled?.points)
    }

    private func refreshZones() {
        guard let m = map else { zoneCache = [:]; return }
        let key = "\(m.id)-\(m.leds.count)-\(m.overriddenCount)"
        guard key != zoneCacheKey else { return }
        let design = ProjectLayout.bundled?.points
        zoneCache = Dictionary(uniqueKeysWithValues: m.leds.map { ($0.id, m.zone(of: $0, design: design)) })
        zoneCacheKey = key
    }

    private func setZone(_ z: AdaptiveEffects.Zone, for id: UUID) {
        guard var m = map else { return }
        m.setZone(z, for: [id])
        carMaps.save(m)
        player.setMap(m)      // non riavvia la riproduzione
        zoneCacheKey = ""
        refreshZones()
    }

    private func resetZone(_ id: UUID) {
        guard var m = map else { return }
        m.resetZone(for: [id])
        carMaps.save(m)
        player.setMap(m)
        zoneCacheKey = ""
        refreshZones()
    }
}

/// Pannello compatto del LED toccato.
struct InspectorPanel: View {
    struct Twin {
        var touched: RGB
        var twin: RGB
        var strategy: AdaptiveY.Strategy?
        var conflict: Double
    }
    let info: LEDInspection
    var twin: Twin? = nil
    var onClose: () -> Void
    var onZone: (AdaptiveEffects.Zone) -> Void
    var onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("LED selezionato").font(.system(size: 22, weight: .bold))
                Text("\(info.letter) / \(String(format: "%03d", info.address))")
                    .font(Theme.monoBody).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentDim))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.4)))
                    .accessibilityIdentifier("inspector-address")
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.surfaceHigh))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspector-close")
            }
            .padding(.bottom, 2)
            Text(info.controllerName).font(Theme.monoSmall).foregroundStyle(Theme.textSecondary).padding(.bottom, 4)
            SpecRow("Ramo", value: info.branch.rawValue + (info.copies > 1 ? "" : " · copia unica"))
            SpecRow(title: "Zona") {
                Menu {
                    ForEach(AdaptiveEffects.Zone.allCases, id: \.self) { z in
                        Button { onZone(z) } label: { if z == info.zone { Label(z.label, systemImage: "checkmark") } else { Text(z.label) } }
                    }
                    if info.origin == .manual {
                        Divider()
                        Button("Ripristina zona automatica", action: onReset)
                    }
                } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(info.zone.label).font(Theme.monoBody).foregroundStyle(Theme.textPrimary)
                            Text(info.origin.rawValue).font(Theme.monoSmall)
                                .foregroundStyle(info.origin == .manual ? Theme.accent : Theme.textSecondary)
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("inspector-zone")
            }
            SpecRow(title: "Colore RGB") {
                if let c = info.rgb {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(rgb: c)).frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.stroke))
                        Text(Theme.hex(c)).font(Theme.monoBody)
                        Text("\(c.r) \(c.g) \(c.b)").font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityIdentifier("inspector-rgb")
                } else {
                    Text("— nessun effetto").font(Theme.monoBody).foregroundStyle(Theme.textSecondary)
                }
            }
            if let t = twin {
                SpecRow(title: "Ideale ● / ○") {
                    HStack(spacing: 8) {
                        swatch(t.touched); swatch(t.twin)
                        Text(String(format: "ΔE %.0f", t.conflict)).font(Theme.monoSmall).foregroundStyle(t.conflict > 20 ? Theme.warning : Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("inspector-twin")
                if let s = t.strategy {
                    Text("Inviato: \(s.label.lowercased()) — l'anteprima mostra questo colore su entrambi i punti")
                        .font(.caption2).foregroundStyle(Theme.textSecondary).padding(.top, 4).lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            Text(info.copies > 1 ? "● punto toccato · ○ copia sul ramo opposto · stesso RGB inviato" : "Un solo punto rilevato per questo indirizzo")
                .font(.caption2).foregroundStyle(Theme.textSecondary).padding(.top, 6).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Theme.surface)
    }
}

extension InspectorPanel {
    func swatch(_ c: RGB) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color(rgb: c)).frame(width: 18, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.stroke))
    }
}

/// Punteggio di compatibilità Y (0–100).
struct ScoreChip: View {
    var score: Int
    var body: some View {
        Text("Y \(score)")
            .font(Theme.monoSmall.weight(.semibold))
            .foregroundStyle(score >= 85 ? Theme.textSecondary : (score >= 60 ? Theme.warning : Theme.danger))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke))
            .accessibilityLabel("Compatibilità Y \(score) su 100")
    }
}

/// Barra di avanzamento sottile.
struct ProgressBar: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceHigh)
                Capsule().fill(Theme.accent).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
    }
}

/// Pulsante a segmento: accento pieno solo se attivo.
struct SegmentStyle: ButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Theme.accentDim : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Theme.accent.opacity(0.6) : Theme.stroke))
            .foregroundStyle(active ? Theme.accent : Theme.textPrimary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Gizmo degli assi che segue la rotazione della camera.
struct AxisGizmo: View {
    var axes: [CGVector]
    var body: some View {
        Canvas { ctx, size in
            guard axes.count == 3 else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let len: CGFloat = 22
            let cols: [Color] = [Color(red: 0.9, green: 0.3, blue: 0.3), Color(red: 0.4, green: 0.85, blue: 0.5), Color(red: 0.4, green: 0.55, blue: 1)]
            for (i, name) in ["X", "Y", "Z"].enumerated() {
                let e = CGPoint(x: c.x + axes[i].dx * len, y: c.y + axes[i].dy * len)
                var p = Path(); p.move(to: c); p.addLine(to: e)
                ctx.stroke(p, with: .color(cols[i]), lineWidth: 1.5)
                ctx.draw(Text(name).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.textSecondary),
                         at: CGPoint(x: c.x + axes[i].dx * (len + 9), y: c.y + axes[i].dy * (len + 9)))
            }
        }
        .frame(width: 70, height: 70)
        .allowsHitTesting(false)
    }
}

/// Scelta del preset: i 60 adattivi a un tocco.
struct PresetPicker: View {
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var adaptiveY: AdaptiveYStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AdaptiveYStatus()
                }
                if !adaptiveY.variants.isEmpty && search.isEmpty {
                    Section {
                        ForEach(adaptiveY.variants) { p in presetRow(p) }
                    } header: { Text("Varianti ottimizzate per la tua auto") }
                }
                Section {
                ForEach(AdaptiveEffects.presets.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { p in presetRow(p) }
                } header: { Text("60 preset") }
            }
            .searchable(text: $search)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }

    private func presetRow(_ p: AdaptiveEffects.Preset) -> some View {
                    Button {
                        player.play(clip: p)
                        dismiss()
                    } label: {
                        HStack {
                            Text(p.name).foregroundStyle(player.clip?.id == p.id ? Theme.accent : Theme.textPrimary)
                            Spacer()
                            if let a = adaptiveY.analysis(for: p.id) {
                                if AdaptiveYStore.isVariant(p.id), let o = adaptiveY.reports[AdaptiveYStore.baseID(p.id)]?.original {
                                    Text("\(o.score)→").font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                                }
                                ScoreChip(score: a.score)
                            }
                            Text(String(format: "%4.1f s%@", p.duration, p.loop ? " ⟲" : "")).font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("preset-\(p.id)")
    }
}

/// Velocità, intensità e colore unico del preset adattivo.
struct TuningSheet: View {
    @EnvironmentObject var player: EffectPlayer
    @State private var useTint = false
    @State private var tint = Color(red: 0.47, green: 0.92, blue: 0.76)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Regolazioni").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Colore condiviso dei gemelli a Y").font(.subheadline)
                Picker("Colore condiviso", selection: $player.shareMode) {
                    ForEach(EffectPlayer.ShareMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(player.shareMode == .adaptiveY
                     ? "Per ogni indirizzo il colore con l'errore percepito minore tra le due copie (dall'analisi della mappa)."
                     : "Regola precedente: vince la copia più luminosa.")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            slider("Velocità", $player.clipSettings.speed, 0.5...2, String(format: "%.2f×", player.clipSettings.speed))
            slider("Intensità", $player.clipSettings.intensity, 0...1, String(format: "%.0f%%", player.clipSettings.intensity * 100))
            Toggle("Colore unico", isOn: $useTint)
            if useTint { ColorPicker("Colore", selection: $tint, supportsOpacity: false) }
            Text("Valgono per i 60 preset; i colori del preset restano quelli originali se il colore unico è spento.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .padding(20)
        .onAppear { useTint = player.clipSettings.tint != nil }
        .onChange(of: useTint) { on in player.clipSettings.tint = on ? RGB(tint) : nil }
        .onChange(of: tint) { c in if useTint { player.clipSettings.tint = RGB(c) } }
    }

    private func slider(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(t); Spacer(); Text(label).font(Theme.monoSmall) }
            Slider(value: v, in: r)
        }
    }
}
