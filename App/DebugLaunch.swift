import SwiftUI

/// Avvio guidato per simulatore e screenshot (solo con argomenti -ALS…; nessun effetto nell'uso normale).
///  -ALSSeedDemo            carica il layout di progetto se non c'è una mappa (centraline A–D da associare)
///  -ALSPartialScan         crea e attiva una "scansione" parziale ricavata dal progetto (indirizzi mancanti)
///  -ALSScreen <sezione>    studio | map3D | controllers | more
///  -ALSPlay <preset>       avvia un preset adattivo in anteprima
///  -ALSStudioMode map      Studio in modalità Mappa (zone)
///  -ALSSelect B:57:left    seleziona un punto fisico (apre l'inspector)
///  -ALSZoneMode            Mappa 3D aperta in modifica zone con alcuni punti selezionati
///  -ALSSelfTest            verifiche nell'app vera (store su disco, player, scena): stampa ALS-SELFTEST …
///  -ALSSerpentineScan      "scansione" con gemelli non speculari (serpentina): copie di ramo destro rimescolate
///  -ALSAnalyzeY            avvia l'analisi Adaptive Y sulla mappa attiva
///  -ALSPresetPicker        apre l'elenco dei preset (punteggi Y) dopo l'analisi
enum DebugLaunch {
    private static var done = false
    static let args = ProcessInfo.processInfo.arguments
    static func has(_ k: String) -> Bool { args.contains(k) }
    static func value(_ k: String) -> String? {
        guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(ui: AppUIState, player: EffectPlayer, carMaps: CarMapStore, hub: ControllerHub, adaptiveY: AdaptiveYStore) {
        guard !done, args.contains(where: { $0.hasPrefix("-ALS") }) else { return }
        done = true
        if has("-ALSSeedDemo") && carMaps.active == nil, let r = ProjectLayout.bundled {
            let m = ProjectLayout.makeMap(r, hub: hub, name: "Layout A1 di progetto (1600 LED)")
            carMaps.save(m)
            carMaps.activeID = m.id
        }
        if has("-ALSPartialScan"), let design = carMaps.maps.first(where: { $0.isDesign }) {
            let m = partialScan(from: design, controllers: hub.controllers)
            carMaps.save(m)
            carMaps.activeID = m.id
        }
        if has("-ALSSerpentineScan"), let design = carMaps.maps.first(where: { $0.isDesign }) {
            let m = serpentineScan(from: design)
            carMaps.save(m)
            carMaps.activeID = m.id
        }
        player.setMap(carMaps.active)
        if has("-ALSAnalyzeY"), let e = player.adaptive { adaptiveY.analyzeAll(e) }
        if has("-ALSPresetPicker") {
            func open() {
                if adaptiveY.isRunning { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: open) } else { ui.showPresetPicker = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: open)
        }
        if let s = value("-ALSScreen"), let sec = MainSection(rawValue: s) { ui.section = sec }
        if value("-ALSStudioMode") == "map" { ui.studioMode = .map }
        if let id = value("-ALSPlay"), let p = AdaptiveEffects.preset(id) { player.play(clip: p) }
        if let sel = value("-ALSSelect"), let m = carMaps.active {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                ui.studioSelection = find(sel, map: m, controllers: player.effectiveControllers)?.id
            }
        }
        if has("-ALSSelfTest") { SelfTest(ui: ui, player: player, carMaps: carMaps, hub: hub, adaptiveY: adaptiveY).start() }
    }

    /// "B:57:left" → punto fisico.
    static func find(_ spec: String, map: CarMap, controllers: [ControllerConfig]) -> PhysicalLED? {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count >= 2, let pixel = Int(parts[1]) else { return nil }
        let list = ControllerResolver.effective(controllers, map: map)
        guard let ci = (0..<list.count).first(where: { controllerLetter($0) == parts[0].uppercased() }) else { return nil }
        let copies = map.leds.filter { $0.key == LEDKey(controller: list[ci].id, pixel: pixel) }
        if parts.count >= 3 {
            let wantLeft = parts[2].lowercased() == "left"
            return copies.first { led in
                if let b = led.branch { return (b == "left") == wantLeft }
                return (map.carPosition(led).z <= 0) == wantLeft
            }
        }
        return copies.first
    }

    /// Montaggio a serpentina di prova: la copia di ramo destro di ogni indirizzo prende la posizione di
    /// un altro indirizzo della stessa centralina (altezza, lato e distanza dal centro diversi).
    static func serpentineScan(from design: CarMap) -> CarMap {
        var byCtrl: [UUID: [PhysicalLED]] = [:]
        for led in design.leds where led.branch == "right" { byCtrl[led.key.controller, default: []].append(led) }
        var rightPos: [LEDKey: SIMD3<Double>] = [:]
        for (_, list) in byCtrl {
            let sorted = list.sorted { $0.key.pixel < $1.key.pixel }
            for (i, led) in sorted.enumerated() { rightPos[led.key] = sorted[(i * 37 + 11) % sorted.count].world }
        }
        let leds = design.leds.map { led -> PhysicalLED in
            let w = led.branch == "right" ? (rightPos[led.key] ?? led.world) : led.world
            return PhysicalLED(key: led.key, world: w, confidence: 0.9, views: 3)
        }
        return CarMap(name: "Scansione serpentina di prova", leds: leds)
    }

    /// Scansione parziale di prova: posizioni del progetto con piccole deviazioni, senza gli indirizzi 10–19
    /// della centralina A e senza il ramo destro degli indirizzi 100–119 della B. Nessuna zona di progetto:
    /// le zone vengono stimate come in una scansione vera.
    static func partialScan(from design: CarMap, controllers: [ControllerConfig]) -> CarMap {
        let list = controllers.sorted { $0.order < $1.order }
        let a = list.indices.contains(0) ? list[0].id : nil
        let b = list.indices.contains(1) ? list[1].id : nil
        var leds: [PhysicalLED] = []
        for led in design.leds {
            if led.key.controller == a, (10...19).contains(led.key.pixel) { continue }
            if led.key.controller == b, (100...119).contains(led.key.pixel), led.branch == "right" { continue }
            let j = Double(led.key.pixel % 7) * 0.002
            leds.append(PhysicalLED(key: led.key, world: led.world + SIMD3(j, -j, 0), confidence: 0.9, views: 3))
        }
        return CarMap(name: "Scansione parziale di prova", leds: leds)
    }
}

/// Verifiche eseguite nell'app vera (simulatore): store su disco, player, scena.
final class SelfTest {
    let ui: AppUIState, player: EffectPlayer, carMaps: CarMapStore, hub: ControllerHub, adaptiveY: AdaptiveYStore
    private var results: [String] = []

    init(ui: AppUIState, player: EffectPlayer, carMaps: CarMapStore, hub: ControllerHub, adaptiveY: AdaptiveYStore) {
        self.ui = ui; self.player = player; self.carMaps = carMaps; self.hub = hub; self.adaptiveY = adaptiveY
    }

    private func report(_ name: String, _ ok: Bool, _ detail: String) {
        let line = "ALS-SELFTEST \(name) \(ok ? "PASS" : "FAIL") \(detail)"
        print(line); NSLog("%@", line)
        results.append(line)
    }

    private func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

    func start() {
        guard let preset = AdaptiveEffects.preset("blueprint") ?? AdaptiveEffects.presets.first else { return }
        player.mode = .preview
        player.play(clip: preset)
        // 1) L'inspector aperto durante l'anteprima non fa ripartire l'effetto.
        after(1.5) { [self] in
            let p1 = player.playhead, id1 = player.clip?.id
            if let m = carMaps.active { ui.studioSelection = DebugLaunch.find("B:57:left", map: m, controllers: player.effectiveControllers)?.id }
            after(1.2) { [self] in
                let p2 = player.playhead
                report("inspector_no_restart", ui.studioSelection != nil && player.isPlaying && player.clip?.id == id1 && p2 > p1 + 0.8,
                       String(format: "playhead %.2f→%.2f s, preset %@", p1, p2, player.clip?.id ?? "-"))
                ui.studioSelection = nil
                after(0.5) { [self] in
                    report("inspector_close_keeps_playback", player.isPlaying && player.clip?.id == id1 && player.playhead > p2,
                           String(format: "playhead %.2f s dopo la chiusura", player.playhead))
                    zoneFlow()
                }
            }
        }
    }

    // 2) B/57: cambia solo la zona del ramo sinistro, salva, riapri lo store dal disco.
    private func zoneFlow() {
        guard var m = carMaps.active,
              let left = DebugLaunch.find("B:57:left", map: m, controllers: player.effectiveControllers),
              let right = DebugLaunch.find("B:57:right", map: m, controllers: player.effectiveControllers) else {
            report("b57_zone_flow", false, "B/57 non trovato nella mappa attiva"); return partial()
        }
        let design = ProjectLayout.bundled?.points
        let rightZoneBefore = m.zone(of: right, design: design)
        let newZone: AdaptiveEffects.Zone = m.zone(of: left, design: design) == .fiancata_anteriore ? .tetto : .fiancata_anteriore
        let playheadBefore = player.playhead
        m.setZone(newZone, for: [left.id])
        carMaps.save(m)
        player.setMap(m)
        let reopened = CarMapStore()     // nuova istanza: rilegge carmaps.json dal disco
        guard let r = reopened.maps.first(where: { $0.id == m.id }),
              let l2 = r.leds.first(where: { $0.id == left.id }), let r2 = r.leds.first(where: { $0.id == right.id }) else {
            report("b57_zone_flow", false, "mappa non riletta"); return partial()
        }
        let zl = r.zone(of: l2, design: design), zr = r.zone(of: r2, design: design)
        report("b57_zone_persist", zl == newZone && l2.zoneOverride == newZone.rawValue && zr == rightZoneBefore && r2.zoneOverride == nil,
               "sinistro \(zl.rawValue) (manuale), destro \(zr.rawValue) (invariato)")
        after(0.6) { [self] in
            report("zone_change_keeps_playback", player.isPlaying && player.playhead > playheadBefore,
                   String(format: "playhead %.2f→%.2f s", playheadBefore, player.playhead))
            // Colore finale condiviso e un solo RGB per B/57.
            let built = SceneContentBuilder.build(map: r, colors: player.colors, coloring: .effect, filter: .all,
                                                  controllers: player.effectiveControllers, model: CarModelStore())
            let iL = built.1.firstIndex(of: left.id), iR = built.1.firstIndex(of: right.id)
            let same = iL != nil && iR != nil && built.0.colors[iL!] == built.0.colors[iR!]
            let list = player.effectiveControllers
            let bID = list.count > 1 ? list[1].id : UUID()
            let split = FrameSplitter.split(player.colors, controllers: list)
            let row = split[bID] ?? []
            report("b57_shared_rgb", same && row.count == (list.count > 1 ? min(list[1].ledCount, IdealProtocol.maxSafeLEDs) : -1) && player.colors[left.key] != nil,
                   "punti con lo stesso colore: \(same), slot B: \(row.count), RGB B/57: \(player.colors[left.key].map { Theme.hex($0) } ?? "-")")
            // Ripristino per non lasciare il profilo modificato.
            var back = r
            back.resetZone(for: [left.id])
            carMaps.save(back)
            player.setMap(back)
            partial()
        }
    }

    // 3) Scansione parziale: gli indirizzi mancanti restano spenti, i successivi tengono il loro numero.
    private func partial() {
        guard let design = carMaps.maps.first(where: { $0.isDesign }) else { report("partial_scan", false, "nessun layout"); return finish() }
        let previous = carMaps.activeID
        let scan = DebugLaunch.partialScan(from: design, controllers: hub.controllers)
        carMaps.save(scan)
        carMaps.activeID = scan.id
        player.setMap(scan)
        checkPartial(scan: scan, previous: previous, attempt: 0)
    }

    /// Ripete il controllo finché l'anteprima ha calcolato un fotogramma sulla nuova mappa (max ~4 s).
    private func checkPartial(scan: CarMap, previous: UUID?, attempt: Int) {
        after(0.4) { [self] in
            let list = player.effectiveControllers
            guard list.count > 1, let eng = player.adaptive else { report("partial_scan", false, "motore non pronto"); return finish() }
            let missing = (10...19).allSatisfy { eng.addresses[0][$0].isEmpty && (player.colors[LEDKey(controller: list[0].id, pixel: $0)] ?? .black) == .black }
            if !missing && attempt < 10 { return checkPartial(scan: scan, previous: previous, attempt: attempt + 1) }
            let kept = eng.addresses[0][20].first?.i == 20 && eng.addresses[1][100].count == 1 && eng.addresses[1][99].count == 2
            report("partial_scan", missing && kept && scan.leds.count < 1600,
                   "\(scan.leds.count) punti; A/10–19 spenti: \(missing); A/20 resta indice 20 e B/100 con un solo punto: \(kept)")
            carMaps.delete(scan.id)
            carMaps.activeID = previous
            player.setMap(carMaps.active)
            adaptiveYCheck()
        }
    }

    // 4) Adaptive Y su una serpentina: l'anteprima è esattamente ciò che va alle centraline.
    private func adaptiveYCheck() {
        guard let design = carMaps.maps.first(where: { $0.isDesign }) else { report("adaptive_y", false, "nessun layout"); return finish() }
        let previous = carMaps.activeID
        let serp = DebugLaunch.serpentineScan(from: design)
        carMaps.save(serp)
        carMaps.activeID = serp.id
        player.setMap(serp)
        guard let engine = player.adaptive, let preset = AdaptiveEffects.preset("ice_scan") else { report("adaptive_y", false, "motore"); return finish() }
        let t0 = Date()
        let rep = AdaptiveY.report(engine, preset)
        let secs = Date().timeIntervalSince(t0)
        report("adaptive_y_analysis", (0...100).contains(rep.original.score) && rep.original.twins > 700 && rep.best.score >= rep.original.classicScore,
               String(format: "Scanner Ghiaccio: classico %d, Adaptive Y %d%@, %d coppie, %.1f s", rep.original.classicScore, rep.original.score,
                      rep.variant.map { " → variante \($0.score) (\($0.params.summary))" } ?? "", rep.original.twins, secs))
        player.shareMode = .adaptiveY
        player.play(clip: preset)
        after(1.0) { [self] in
            player.pause()
            let list = player.effectiveControllers
            let analysis = adaptiveY.analysis(for: preset.id)
            let rows = AdaptiveY.frame(engine, preset, elapsed: player.playhead, strategy: { analysis?.strategy($0) ?? .highlightWeighted })
            let expected = FramePack.keyed(rows.map { $0.map { FramePack.adjust($0, player.clipSettings) } }, controllers: list)
            let same = expected == player.colors
            let split = FrameSplitter.split(player.colors, controllers: list)
            let perAddress = list.allSatisfy { (split[$0.id]?.count ?? 0) == min($0.ledCount, IdealProtocol.maxSafeLEDs) }
            report("adaptive_y_preview_is_reproducible", same && perAddress,
                   "anteprima = fotogramma inviato: \(same); un RGB per indirizzo su tutte le centraline: \(perAddress)")
            carMaps.delete(serp.id)
            carMaps.activeID = previous
            player.setMap(carMaps.active)
            player.resume()
            finish()
        }
    }

    private func finish() {
        let failed = results.filter { $0.contains(" FAIL ") }.count
        let line = "ALS-SELFTEST DONE \(results.count - failed)/\(results.count) PASS"
        print(line); NSLog("%@", line)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("selftest.txt")
        try? (results + [line]).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
