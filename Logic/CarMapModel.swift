import Foundation
import simd

/// LED fisico mappato in 3D. Più LED fisici possono avere la stessa chiave logica (cablaggio a Y).
struct PhysicalLED: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: LEDKey
    /// Posizione nel mondo della scansione AR (metri).
    var world: SIMD3<Double>
    var confidence: Double
    var views: Int
    var manual = false
    /// Parte dell'auto indicata dal layout di progetto (es. "tetto", "cofano"); nil per i LED scansionati.
    var part: String? = nil
    /// Ramo della Y ("left"/"right") indicato dal layout di progetto.
    var branch: String? = nil
    /// Zona corretta a mano (valore di AdaptiveEffects.Zone); nil = zona automatica.
    /// Riguarda solo questo punto fisico: la copia a Y dello stesso indirizzo può avere un'altra zona.
    var zoneOverride: String? = nil
}

/// Mappa 3D dell'impianto: LED fisici + allineamento al modello dell'auto.
struct CarMap: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var leds: [PhysicalLED]
    var alignment = CarAlignment()
    /// Osservazioni grezze conservate per poter aggiungere viste e ricalcolare.
    var observations: [LEDObservation] = []
    var viewCount = 0
    /// Mappa dimostrativa generata dall'app (non è la tua auto): sempre indicata come tale.
    var isDemo = false
    /// "design" = posizioni prese dal file di progetto (Blender), non misurate sull'auto.
    var source: String? = nil
    /// Esito dell'ultimo allineamento automatico al progetto (da mostrare all'utente).
    var alignmentInfo: String? = nil

    var isDesign: Bool { source == "design" }
    /// Vero solo per le mappe ottenute dalla scansione (né dimostrative né da progetto).
    var isMeasured: Bool { !isDemo && !isDesign }

    func carPosition(_ led: PhysicalLED) -> SIMD3<Double> { alignment.toCar(led.world) }

    var effectPoints: [EffectPoint] { leds.map { EffectPoint(key: $0.key, position: carPosition($0)) } }

    /// Gli altri LED fisici comandati dallo stesso pixel logico.
    func twins(of led: PhysicalLED) -> [PhysicalLED] { leds.filter { $0.key == led.key && $0.id != led.id } }

    func coverage(codebook: Codebook) -> (found: Int, total: Int, perController: [UUID: (Int, Int)]) {
        let keys = Set(leds.map { $0.key })
        var per: [UUID: (Int, Int)] = [:]
        for e in codebook.entries {
            let f = keys.filter { $0.controller == e.controller && $0.pixel < e.count }.count
            per[e.controller] = (f, e.count)
        }
        return (per.values.reduce(0) { $0 + $1.0 }, codebook.total, per)
    }

    func missing(codebook: Codebook) -> [LEDKey] {
        let keys = Set(leds.map { $0.key })
        var out: [LEDKey] = []
        for e in codebook.entries {
            for i in 0..<e.count where !keys.contains(LEDKey(controller: e.controller, pixel: i)) {
                out.append(LEDKey(controller: e.controller, pixel: i))
            }
        }
        return out
    }
}

// MARK: Zone dei LED (automatiche e corrette a mano)

extension CarMap {
    /// Zona automatica: quella del layout se nota, altrimenti quella del punto di progetto più vicino,
    /// altrimenti una stima dalla forma dell'auto.
    static func autoZone(position: SIMD3<Double>, part: String?, design: [LEDLayoutImport.Point]?) -> AdaptiveEffects.Zone {
        if let part, let z = AdaptiveEffects.Zone(rawValue: part) { return z }
        if let pts = design, !pts.isEmpty {
            var best = pts[0], bd = Double.infinity
            for p in pts { let d = simd_distance_squared(p.position, position); if d < bd { bd = d; best = p } }
            if let zn = best.zone, let z = AdaptiveEffects.Zone(rawValue: zn) { return z }
        }
        switch ZoneClassifier.zone(of: position) {
        case .roof: return .tetto
        case .front: return .cofano
        case .rear: return .portellone
        default: return position.x >= 0 ? .fiancata_anteriore : .fiancata_posteriore
        }
    }

    func autoZone(of led: PhysicalLED, design: [LEDLayoutImport.Point]?) -> AdaptiveEffects.Zone {
        CarMap.autoZone(position: carPosition(led), part: led.part, design: design)
    }

    /// Zona usata dagli effetti: la correzione manuale se c'è, altrimenti l'automatica.
    func zone(of led: PhysicalLED, design: [LEDLayoutImport.Point]?) -> AdaptiveEffects.Zone {
        if let o = led.zoneOverride, let z = AdaptiveEffects.Zone(rawValue: o) { return z }
        return autoZone(of: led, design: design)
    }

    /// Assegna una zona ai punti fisici indicati. Coordinate e indirizzi non cambiano.
    @discardableResult
    mutating func setZone(_ zone: AdaptiveEffects.Zone, for ids: Set<UUID>) -> Int {
        var n = 0
        for i in leds.indices where ids.contains(leds[i].id) { leds[i].zoneOverride = zone.rawValue; n += 1 }
        return n
    }

    /// Torna alla zona automatica per i punti fisici indicati.
    @discardableResult
    mutating func resetZone(for ids: Set<UUID>) -> Int {
        var n = 0
        for i in leds.indices where ids.contains(leds[i].id) && leds[i].zoneOverride != nil { leds[i].zoneOverride = nil; n += 1 }
        return n
    }

    var overriddenCount: Int { leds.filter { $0.zoneOverride != nil }.count }

    /// Punti della stessa striscia tra due punti della stessa centralina: per ogni indirizzo intermedio
    /// sceglie la copia fisica più vicina al punto precedente, così con il cablaggio a Y segue un solo ramo.
    func stripPath(from a: UUID, to b: UUID) -> [UUID] {
        guard let la = leds.first(where: { $0.id == a }), let lb = leds.first(where: { $0.id == b }),
              la.key.controller == lb.key.controller else { return [] }
        let step = la.key.pixel <= lb.key.pixel ? 1 : -1
        var path = [la.id]
        var last = carPosition(la)
        var px = la.key.pixel
        while px != lb.key.pixel {
            px += step
            if px == lb.key.pixel { path.append(lb.id); break }
            let copies = leds.filter { $0.key.controller == la.key.controller && $0.key.pixel == px }
            guard let best = copies.min(by: { simd_distance(carPosition($0), last) < simd_distance(carPosition($1), last) }) else { continue }
            path.append(best.id)
            last = carPosition(best)
        }
        return path
    }

    /// Campioni per le 60 animazioni adattive: un punto per LED fisico, con la sua zona (corretta o automatica),
    /// raggruppati per centralina (ordine della lista) e indirizzo: la centralina riceve un solo RGB per indirizzo.
    func adaptiveEngine(controllers: [ControllerConfig], design: [LEDLayoutImport.Point]?) -> AdaptiveEffects.Engine? {
        let list = controllers.sorted { $0.order < $1.order }
        guard !list.isEmpty else { return nil }
        let index = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0) })
        var pts: [Int: [Int: [AdaptiveEffects.Point]]] = [:]
        for led in leds {
            guard let ci = index[led.key.controller] else { continue }
            pts[ci, default: [:]][led.key.pixel, default: []].append(AdaptiveEffects.Point(position: carPosition(led), zone: zone(of: led, design: design)))
        }
        return AdaptiveEffects.Engine(addressCounts: list.map { min($0.ledCount, IdealProtocol.maxSafeLEDs) }, points: pts)
    }
}

/// Lettura/scrittura del profilo delle mappe (carmaps.json), usata dall'app e dai test.
enum CarMapArchive {
    static func load(_ url: URL) -> [CarMap] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CarMap].self, from: data)) ?? []
    }

    static func save(_ maps: [CarMap], to url: URL) throws {
        try JSONEncoder().encode(maps).write(to: url, options: .atomic)
    }
}
