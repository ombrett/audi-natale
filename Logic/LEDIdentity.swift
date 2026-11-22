import Foundation

/// Identità di un pixel logico: centralina + indice. Due LED fisici cablati in parallelo (a Y)
/// condividono la stessa chiave: non possono avere colori diversi.
struct LEDKey: Hashable, Codable, Comparable, CustomStringConvertible {
    var controller: UUID
    var pixel: Int

    static func < (a: LEDKey, b: LEDKey) -> Bool {
        a.controller == b.controller ? a.pixel < b.pixel : a.controller.uuidString < b.controller.uuidString
    }

    var description: String { "\(controller.uuidString.prefix(4))#\(pixel)" }
}

/// Configurazione persistente di una centralina.
struct ControllerConfig: Codable, Identifiable, Equatable {
    /// Identificativo stabile dell'app (non cambia se iOS rinnova l'identificatore BLE).
    var id = UUID()
    var name: String
    /// Nome pubblicizzato via BLE, es. "ISP-B0717F".
    var bleName: String
    /// Identificatore CoreBluetooth dell'ultima connessione (per riconnettersi senza scansione).
    var peripheralID: UUID?
    var ledCount: Int
    var order: Int
    /// Quanti LED fisici riceve ogni pixel (2 = due file a Y sulla stessa linea dati).
    var copiesPerPixel: Int = 2
    var enabled = true
    /// Colore distintivo nell'interfaccia (indice in una tavolozza).
    var tint: Int = 0
}

/// Spazio di codici condiviso da tutte le centraline: la mappatura accende i codici su tutte
/// contemporaneamente e ogni LED è identificato in un'unica scansione.
struct Codebook: Equatable {
    struct Entry: Equatable { let controller: UUID; let count: Int; let offset: Int }
    let entries: [Entry]
    let total: Int
    let plan: MappingPlan

    init(controllers: [ControllerConfig]) {
        var list: [Entry] = []
        var offset = 0
        for c in controllers.filter({ $0.enabled }).sorted(by: { $0.order < $1.order }) {
            let n = max(0, min(c.ledCount, IdealProtocol.maxSafeLEDs))
            list.append(Entry(controller: c.id, count: n, offset: offset))
            offset += n
        }
        entries = list
        total = offset
        plan = MappingPlan(ledCount: max(offset, 1))
    }

    func globalIndex(_ key: LEDKey) -> Int? {
        guard let e = entries.first(where: { $0.controller == key.controller }), key.pixel >= 0, key.pixel < e.count else { return nil }
        return e.offset + key.pixel
    }

    func key(forGlobal g: Int) -> LEDKey? {
        guard let e = entries.first(where: { g >= $0.offset && g < $0.offset + $0.count }) else { return nil }
        return LEDKey(controller: e.controller, pixel: g - e.offset)
    }

    /// Disegno di ogni centralina per un fotogramma del piano di mappatura.
    func targets(for frame: MappingPlan.Frame, on: RGB) -> [UUID: [RGB]] {
        var out: [UUID: [RGB]] = [:]
        for e in entries {
            out[e.controller] = (0..<e.count).map { plan.isOn(index: e.offset + $0, in: frame) ? on : .black }
        }
        return out
    }
}

enum FrameSplitter {
    /// Divide i colori per pixel logico nei disegni delle singole centraline.
    static func split(_ colors: [LEDKey: RGB], controllers: [ControllerConfig], fallback: RGB = .black) -> [UUID: [RGB]] {
        var out: [UUID: [RGB]] = [:]
        for c in controllers where c.enabled {
            let n = max(0, min(c.ledCount, IdealProtocol.maxSafeLEDs))
            out[c.id] = (0..<n).map { colors[LEDKey(controller: c.id, pixel: $0)] ?? fallback }
        }
        return out
    }
}
