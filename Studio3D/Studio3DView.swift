import SwiftUI
import UniformTypeIdentifiers

/// Mappa 3D / 3D Studio: modello dell'auto, LED mappati, selezione, filtri, allineamento.
struct Studio3DView: View {
    @EnvironmentObject var hub: ControllerHub
    @EnvironmentObject var carMaps: CarMapStore
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var model: CarModelStore

    @State private var coloring: LEDColoring = .controller
    @State private var filter: LEDFilter = .all
    @State private var camera: CameraPreset = .iso
    @State private var camToken = 0
    @State private var selectedID: UUID?
    @State private var showImporter = false
    @State private var showAlign = false
    @State private var importError: String?
    @State private var shareItem: ShareItem?
    @State private var lightResult: String?
    @State private var importKind: ImportKind = .model
    @State private var pendingLayout: PendingLayout?
    @State private var layoutError: String?
    @State private var zoneMode = false
    @State private var zoneSel: Set<UUID> = []
    @State private var zoneCache: [UUID: AdaptiveEffects.Zone] = [:]
    @State private var zoneCacheMap: UUID?
    @State private var zoneNote: String?

    enum ImportKind { case model, layout }
    struct PendingLayout: Identifiable {
        let id = UUID()
        let result: LEDLayoutImport.Result
        let name: String
    }

    private var map: CarMap? { carMaps.active }

    var body: some View {
        let built = SceneContentBuilder.build(map: map, colors: player.colors, coloring: zoneMode ? .zone : coloring, filter: filter,
                                              controllers: hub.controllers, selected: zoneMode ? nil : selectedID,
                                              highlightIDs: zoneMode ? zoneSel : [], zones: zoneCache, model: model)
        ScrollView {
            VStack(spacing: 14) {
                Card {
                    ZStack(alignment: .topLeading) {
                        CarSceneView(content: built.0, camera: camera, cameraToken: camToken) { idx in
                            let id = idx.flatMap { built.1.indices.contains($0) ? built.1[$0] : nil }
                            if zoneMode {
                                if let id { if zoneSel.contains(id) { zoneSel.remove(id) } else { zoneSel.insert(id) } }
                            } else {
                                selectedID = id
                            }
                        }
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 6) {
                            if model.isProvisional { Badge(text: "MODELLO PROVVISORIO — non è il modello fedele dell'A1", color: Theme.warning) }
                            if map?.isDemo == true { Badge(text: "MAPPA DIMOSTRATIVA — non è la tua auto", color: Theme.warning) }
                            if map?.isDesign == true { Badge(text: "POSIZIONI DA PROGETTO — non misurate sull'auto", color: Theme.warning) }
                            if map == nil { Badge(text: "NESSUNA MAPPA", color: Theme.danger) }
                        }
                        .padding(10)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CameraPreset.allCases) { p in
                                Button(p.label) { camera = p; camToken += 1 }
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Capsule().fill(camera == p ? Theme.accentDim : Theme.surfaceHigh))
                            }
                        }
                    }
                    Text(zoneMode ? "Modifica zone: tocca i punti per selezionarli o deselezionarli (bianchi = selezionati)."
                                  : "Trascina per ruotare a 360°, pizzica per ingrandire, tocca un LED per i dettagli.")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                if zoneMode { zoneCard } else if let led = map?.leds.first(where: { $0.id == selectedID }) { selectionCard(led) }
                displayCard
                mapCard
                modelCard
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Mappa 3D")
        .toolbar {
            Menu {
                ForEach(carMaps.maps) { m in
                    Button { carMaps.activeID = m.id; player.setMap(m) } label: {
                        Label(m.name, systemImage: m.id == carMaps.activeID ? "checkmark" : (m.isDemo ? "testtube.2" : (m.isDesign ? "pencil.and.ruler" : "map")))
                    }
                }
                Divider()
                Button { loadBundledLayout() } label: { Label("Carica layout A1 di progetto (1600 LED)", systemImage: "pencil.and.ruler") }
                    .disabled(ProjectLayout.bundledURL == nil)
                Button { importKind = .layout; showImporter = true } label: { Label("Importa layout LED (JSON)…", systemImage: "doc.badge.plus") }
                Button { createDemo() } label: { Label("Crea mappa dimostrativa", systemImage: "testtube.2") }
                    .disabled(hub.controllers.isEmpty)
                Button {
                    if let url = try? carMaps.exportJSON() { shareItem = ShareItem(url: url) }
                } label: { Label("Esporta mappe (JSON)", systemImage: "square.and.arrow.up") }
                if let m = map {
                    Button(role: .destructive) { carMaps.delete(m.id); player.setMap(carMaps.active) } label: { Label("Elimina mappa attiva", systemImage: "trash") }
                }
            } label: { Image(systemName: "map") }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importKind == .layout
                      ? [.json, .data]
                      : [UTType(filenameExtension: "glb") ?? .data, .usdz, UTType(filenameExtension: "scn") ?? .data, .data]) { result in
            switch (importKind, result) {
            case (.model, .success(let url)):
                do { try model.importModel(from: url); importError = nil } catch { importError = error.localizedDescription }
            case (.layout, .success(let url)):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                readLayout(try? Data(contentsOf: url), name: "Layout " + url.deletingPathExtension().lastPathComponent)
            case (.model, .failure(let e)):
                importError = e.localizedDescription
            case (.layout, .failure(let e)):
                layoutError = e.localizedDescription
            }
        }
        .alert(item: $pendingLayout) { p in
            Alert(title: Text("Importa layout di progetto"),
                  message: Text(layoutSummary(p.result)),
                  primaryButton: .default(Text("Importa")) { applyLayout(p) },
                  secondaryButton: .cancel(Text("Annulla")))
        }
        .alert("Layout non importato", isPresented: Binding(get: { layoutError != nil }, set: { if !$0 { layoutError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(layoutError ?? "") }
        .sheet(isPresented: $showAlign) { AlignmentSheet() }
        .sheet(item: $shareItem) { ActivityView(items: [$0.url]) }
        .onAppear { player.setMap(map); refreshZones() }
        .onChange(of: carMaps.activeID) { _ in zoneSel = []; refreshZones() }
    }

    // MARK: Card

    private func selectionCard(_ led: PhysicalLED) -> some View {
        let car = map?.carPosition(led) ?? .zero
        let twins = map?.twins(of: led) ?? []
        let color = player.colors[led.key]
        return Card(title: "LED selezionato", systemImage: "scope") {
            HStack {
                RoundedRectangle(cornerRadius: 3).fill(ControllerPalette.color(hub.config(led.key.controller)?.tint ?? 0)).frame(width: 5, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(hub.name(of: led.key.controller)) · pixel \(led.key.pixel)").font(.headline)
                    Text("Zona: \(ZoneClassifier.zone(of: car).label)\(led.part.map { " · parte: \($0)" } ?? "")\(led.branch.map { " · ramo \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if let color { Circle().fill(Color(rgb: color)).frame(width: 22, height: 22) }
            }
            info("Posizione (auto)", String(format: "x %.2f  y %.2f  z %.2f m", car.x, car.y, car.z))
            if let z = zoneCache[led.id] {
                info("Zona effetti", z.label + (led.zoneOverride != nil ? " · corretta a mano" : " · automatica"))
            }
            if map?.isDesign == true {
                info("Origine", "posizione da progetto (non misurata)")
            } else {
                info("Affidabilità", String(format: "%.0f%% · %ld viste%@", led.confidence * 100, led.views, led.manual ? " · corretto a mano" : ""))
            }
            info("Stesso pixel (a Y)", twins.isEmpty ? "nessun altro LED fisico" : "\(twins.count) altro LED fisico: hanno sempre lo stesso colore")
            HStack(spacing: 8) {
                Button("Accendi") { light(led.key) }.buttonStyle(AccentButtonStyle(filled: false)).enabled(player.liveReady)
                Stepper("Pixel", onIncrement: { reassign(led, by: 1) }, onDecrement: { reassign(led, by: -1) }).labelsHidden()
                Button(role: .destructive) { remove(led) } label: { Image(systemName: "trash") }
                    .buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false)).frame(width: 60)
            }
            if let lightResult { Text(lightResult).font(.caption).foregroundStyle(Theme.textSecondary) }
        }
    }

    private var zoneCard: some View {
        let selected = map?.leds.filter { zoneSel.contains($0.id) } ?? []
        let manual = selected.filter { $0.zoneOverride != nil }.count
        let selZones = Set(selected.compactMap { zoneCache[$0.id] })
        return Card(title: "Modifica zone", systemImage: "square.dashed.inset.filled") {
            Text(selected.isEmpty ? "Nessun punto selezionato" : "\(selected.count) punti selezionati" + (manual > 0 ? " · \(manual) già corretti a mano" : ""))
                .font(.headline)
            if selZones.count == 1, let z = selZones.first { info("Zona attuale", z.label) }
            else if selZones.count > 1 { info("Zone attuali", "\(selZones.count) diverse") }
            Menu {
                ForEach(AdaptiveEffects.Zone.allCases, id: \.self) { z in
                    Button { assignZone(z) } label: { Label(z.label, systemImage: "circle.fill") }
                }
            } label: {
                Label("Assegna zona…", systemImage: "tag").frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(selected.isEmpty)
            HStack(spacing: 8) {
                Button("Ripristina zona automatica") { resetZones() }
                    .buttonStyle(AccentButtonStyle(filled: false)).enabled(manual > 0)
                Button("Deseleziona") { zoneSel = [] }
                    .buttonStyle(AccentButtonStyle(filled: false)).enabled(!selected.isEmpty)
            }
            Button("Completa la striscia tra i 2 punti") { completeStrip() }
                .buttonStyle(AccentButtonStyle(filled: false))
                .enabled(selected.count == 2 && selected[0].key.controller == selected[1].key.controller)
            Text("La correzione vale per il singolo punto fisico: le due copie a Y dello stesso indirizzo possono stare in zone diverse e mostrano comunque lo stesso colore. Coordinate e indirizzi non cambiano.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
            if let zoneNote { Text(zoneNote).font(.caption).foregroundStyle(Theme.ok) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], spacing: 6) {
                ForEach(AdaptiveEffects.Zone.allCases, id: \.self) { z in
                    HStack(spacing: 6) { Circle().fill(ZonePalette.color(z)).frame(width: 10, height: 10); Text(z.label).font(.caption2) }
                }
            }
        }
    }

    private var displayCard: some View {
        Card(title: "Visualizzazione", systemImage: "eye") {
            Toggle("Modifica zone", isOn: $zoneMode.animation())
                .disabled(map == nil)
                .onChange(of: zoneMode) { on in if on { selectedID = nil; refreshZones() } else { zoneSel = [] } }
            Picker("Colori", selection: $coloring) {
                ForEach(LEDColoring.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Mostra", selection: $filter) {
                Text("Impianto completo").tag(LEDFilter.all)
                ForEach(hub.controllers) { c in Text("Solo \(c.name)").tag(LEDFilter.controller(c.id)) }
                ForEach(CarZone.allCases.filter { $0 != .all }) { z in Text("Zona: \(z.label)").tag(LEDFilter.zone(z)) }
            }
            .pickerStyle(.menu)
            if coloring == .effect && player.colors.isEmpty {
                Text("Avvia un effetto dalla sezione Effetti per vederlo qui.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var mapCard: some View {
        Card(title: "Mappa", systemImage: "point.3.filled.connected.trianglepath.dotted") {
            if let m = map {
                let cov = m.coverage(codebook: hub.codebook)
                info("Nome", m.name)
                info("LED fisici", "\(m.leds.count)")
                info("Pixel coperti", "\(cov.found) / \(cov.total)")
                if let note = m.alignmentInfo { Text(note).font(.caption).foregroundStyle(Theme.textSecondary) }
                if m.isDesign {
                    Text("Posizioni prese dal progetto Blender: corrispondono all'auto solo se le strisce sono montate come nel progetto. Verifica con \"Accendi\" su alcuni LED; una scansione misura quelle vere.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    info("Viste", "\(m.viewCount)")
                }
                let low = m.leds.filter { $0.confidence < 0.5 }.count
                if low > 0 { Text("\(low) LED con affidabilità bassa (in rosso con colori \"Affidabilità\").").font(.caption).foregroundStyle(Theme.warning) }
                Button { showAlign = true } label: { Label("Allinea al modello", systemImage: "move.3d") }
                    .buttonStyle(AccentButtonStyle(filled: false))
                    .disabled(!m.isMeasured)
            } else {
                Text("Scansiona l'auto dalla sezione Scansione, carica il layout di progetto (posizioni previste, non misurate) oppure crea una mappa dimostrativa.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Button("Layout di progetto") { loadBundledLayout() }.buttonStyle(AccentButtonStyle(filled: false)).enabled(ProjectLayout.bundledURL != nil)
                    Button("Dimostrativa") { createDemo() }.buttonStyle(AccentButtonStyle(filled: false)).enabled(!hub.controllers.isEmpty)
                }
            }
        }
    }

    private var modelCard: some View {
        Card(title: "Modello dell'auto", systemImage: "car.side") {
            ColorPicker("Colore carrozzeria", selection: Binding(get: { Color(rgb: model.bodyColor) }, set: { model.bodyColor = RGB($0) }), supportsOpacity: false)
            if model.importedURL == nil && CarModelStore.projectModelURL != nil {
                Toggle("Modello A1 del progetto", isOn: $model.useProjectModel)
            }
            if model.isProvisional {
                Text("Modello provvisorio con le dimensioni dell'Audi A1 Sportback 2020 (4,03 × 1,74 × 1,41 m). Per la forma reale importa un file GLB, USDZ o SCN di cui hai la licenza d'uso.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else if model.isProjectModel {
                Text("Modello dal tuo progetto Blender (Audi_A1_LED1600.glb), nelle stesse coordinate del layout LED. Il colore si applica alla carrozzeria.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Modello importato. Il colore viene applicato ai materiali chiamati \"paint\"/\"body\": se non cambia, il file usa nomi diversi.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 8) {
                Button("Importa GLB/USDZ/SCN") { importKind = .model; showImporter = true }.buttonStyle(AccentButtonStyle(filled: false))
                if model.importedURL != nil {
                    Button { model.yawSteps = (model.yawSteps + 1) % 4 } label: { Image(systemName: "rotate.right") }
                        .buttonStyle(AccentButtonStyle(filled: false)).frame(width: 60)
                    Button { model.removeModel() } label: { Image(systemName: "trash") }
                        .buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false)).frame(width: 60)
                }
            }
            if let importError { Text(importError).font(.caption).foregroundStyle(Theme.danger) }
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.caption).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(v).font(Theme.monoSmall).multilineTextAlignment(.trailing)
        }
    }

    // MARK: Azioni

    private func createDemo() {
        let m = DemoLayout.make(controllers: hub.controllers)
        carMaps.save(m)
        player.setMap(m)
    }

    private func refreshZones() {
        guard let m = map else { zoneCache = [:]; zoneCacheMap = nil; return }
        let design = ProjectLayout.bundled?.points
        zoneCache = Dictionary(uniqueKeysWithValues: m.leds.map { ($0.id, m.zone(of: $0, design: design)) })
        zoneCacheMap = m.id
    }

    private func assignZone(_ z: AdaptiveEffects.Zone) {
        guard var m = map else { return }
        let n = m.setZone(z, for: zoneSel)
        carMaps.save(m)
        player.setMap(m)
        refreshZones()
        zoneNote = "\(n) punti in \(z.label). Salvato nel profilo, già usato dagli effetti adattivi."
    }

    private func resetZones() {
        guard var m = map else { return }
        let n = m.resetZone(for: zoneSel)
        carMaps.save(m)
        player.setMap(m)
        refreshZones()
        zoneNote = "\(n) punti tornati alla zona automatica."
    }

    private func completeStrip() {
        guard let m = map, zoneSel.count == 2 else { return }
        let ids = Array(zoneSel)
        let path = m.stripPath(from: ids[0], to: ids[1])
        zoneSel.formUnion(path)
        zoneNote = "Selezionati \(path.count) punti lungo la striscia."
    }

    private func loadBundledLayout() {
        readLayout(ProjectLayout.bundledURL.flatMap { try? Data(contentsOf: $0) }, name: "Layout A1 di progetto (1600 LED)")
    }

    private func readLayout(_ data: Data?, name: String) {
        guard let data else { layoutError = "File non leggibile."; return }
        do { pendingLayout = PendingLayout(result: try LEDLayoutImport.parse(data), name: name) }
        catch { layoutError = error.localizedDescription }
    }

    private func layoutSummary(_ r: LEDLayoutImport.Result) -> String {
        var lines = ["\(r.physicalCount) LED fisici, \(r.logicalCount) pixel. Posizioni previste dal progetto, non misurate."]
        for a in ProjectLayout.assignments(r, controllers: hub.controllers) {
            let dest = a.existing.map { "→ \($0.name)" } ?? "→ nuova \"Pacco \(a.fileName)\" da associare"
            lines.append("\(a.fileName): \(a.addressCount) pixel × \(a.branches) \(dest)")
        }
        lines.append("L'ordine segue la lista Centraline: se un pacco è collegato a un'altra centralina, riordinale prima.")
        lines += r.warnings
        return lines.joined(separator: "\n")
    }

    private func applyLayout(_ p: PendingLayout) {
        let m = ProjectLayout.makeMap(p.result, hub: hub, name: p.name)
        carMaps.save(m)
        player.setMap(m)
        selectedID = nil
    }

    private func light(_ key: LEDKey) {
        lightResult = "Invio…"
        player.sendOnce([key: RGB(r: 255, g: 255, b: 255)]) { err in lightResult = err ?? "Acceso \(hub.name(of: key.controller)) #\(key.pixel) (gli altri spenti)" }
    }

    private func reassign(_ led: PhysicalLED, by delta: Int) {
        guard var m = map, let i = m.leds.firstIndex(where: { $0.id == led.id }) else { return }
        let maxPixel = (hub.config(led.key.controller)?.ledCount ?? 1) - 1
        m.leds[i].key.pixel = min(max(m.leds[i].key.pixel + delta, 0), maxPixel)
        m.leds[i].manual = true
        carMaps.save(m)
        player.setMap(m)
    }

    private func remove(_ led: PhysicalLED) {
        guard var m = map else { return }
        m.leds.removeAll { $0.id == led.id }
        carMaps.save(m)
        player.setMap(m)
        selectedID = nil
    }
}

/// Allineamento manuale/automatico della nuvola di LED al modello.
struct AlignmentSheet: View {
    @EnvironmentObject var carMaps: CarMapStore
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var hub: ControllerHub
    @Environment(\.dismiss) private var dismiss
    @State private var a = CarAlignment()
    @State private var fitNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Allinea al progetto (usa gli indirizzi dei LED)") {
                        guard let m = carMaps.active, let fit = ProjectLayout.register(m, controllers: hub.controllers) else {
                            fitNote = "Nessun pixel in comune con il layout di progetto."
                            return
                        }
                        a = fit.alignment
                        fitNote = (fit.isGood ? "" : "Attenzione, poco affidabile: ") + fit.summary
                    }
                } footer: {
                    Text(fitNote ?? "Confronta ogni pixel scansionato con la sua posizione nel progetto Blender: trova anche il verso dell'auto. I LED montati diversamente dal progetto vengono ignorati nel calcolo e restano dove li ha misurati la scansione.")
                }
                Section {
                    Button("Allineamento per forma") {
                        if let m = carMaps.active { a = AutoAlign.fit(m.leds.map { $0.world }) }
                    }
                    Button("Inverti davanti/dietro") { a.yaw += .pi }
                } footer: {
                    Text("Per forma: porta l'asse più lungo della nuvola di LED lungo l'auto. Il verso avanti/dietro va scelto a mano.")
                }
                Section("Rotazione") {
                    Slider(value: Binding(get: { a.yaw * 180 / .pi }, set: { a.yaw = $0 * .pi / 180 }), in: -180...180) { Text("Imbardata") }
                    Text(String(format: "%.0f°", a.yaw * 180 / .pi)).font(Theme.monoSmall)
                }
                Section("Posizione (m)") {
                    slider("Avanti/dietro", Binding(get: { a.offset.x }, set: { a.offset.x = $0 }), -5...5)
                    slider("Altezza", Binding(get: { a.offset.y }, set: { a.offset.y = $0 }), -3...3)
                    slider("Sinistra/destra", Binding(get: { a.offset.z }, set: { a.offset.z = $0 }), -5...5)
                }
                Section("Scala") {
                    slider("Scala", $a.scale, 0.8...1.2)
                }
            }
            .navigationTitle("Allinea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        if var m = carMaps.active { m.alignment = a; carMaps.save(m); player.setMap(m) }
                        dismiss()
                    }
                }
            }
            .onAppear { a = carMaps.active?.alignment ?? CarAlignment() }
        }
        .preferredColorScheme(.dark)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).font(Theme.monoSmall) }
            Slider(value: value, in: range)
        }
    }
}
