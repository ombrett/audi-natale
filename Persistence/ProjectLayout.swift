import Foundation

/// Importa un layout LED di progetto (JSON esportato da Blender) come mappa 3D dell'app.
/// Le posizioni sono quelle PREVISTE dal progetto: la mappa resta etichettata "da progetto"
/// finché una scansione non misura l'auto vera.
enum ProjectLayout {
    static var bundledURL: URL? { Bundle.main.url(forResource: "Audi_A1_LED1600", withExtension: "json") }

    /// Layout di progetto incluso nell'app, letto una volta.
    static let bundled: LEDLayoutImport.Result? = bundledURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? LEDLayoutImport.parse($0) }

    /// Posizioni di progetto con le chiavi delle centraline attuali (pacco n → n-esima della lista).
    static func designPoints(controllers: [ControllerConfig]) -> [EffectPoint]? {
        guard let r = bundled else { return nil }
        let list = controllers.sorted { $0.order < $1.order }
        let pts = r.points.compactMap { p -> EffectPoint? in
            guard list.indices.contains(p.controller) else { return nil }
            return EffectPoint(key: LEDKey(controller: list[p.controller].id, pixel: p.pixel), position: p.position)
        }
        return pts.isEmpty ? nil : pts
    }

    /// Allinea una mappa scansionata al progetto; nil se il progetto non c'è o i LED non corrispondono abbastanza.
    static func register(_ map: CarMap, controllers: [ControllerConfig]) -> LayoutRegistration.Fit? {
        guard let design = designPoints(controllers: controllers) else { return nil }
        return LayoutRegistration.fit(scan: map.leds.map { EffectPoint(key: $0.key, position: $0.world) }, design: design)
    }

    struct Assignment: Identifiable {
        let id = UUID()
        let fileName: String          // "A", "B", …
        let addressCount: Int
        let branches: Int
        let ledCount: Int             // LED fisici del file per questa centralina
        let existing: ControllerConfig?   // nil = verrà creata una centralina da associare
    }

    /// La centralina n-esima del file va alla n-esima centralina dell'app (ordine della lista Centraline).
    static func assignments(_ r: LEDLayoutImport.Result, controllers: [ControllerConfig]) -> [Assignment] {
        let list = controllers.sorted { $0.order < $1.order }
        return r.controllers.enumerated().map { i, c in
            Assignment(fileName: c.name, addressCount: c.addressCount, branches: c.branches,
                       ledCount: r.points.filter { $0.controller == i }.count,
                       existing: list.indices.contains(i) ? list[i] : nil)
        }
    }

    /// Crea le centraline mancanti come segnaposto, allinea pixel e copie a Y, e costruisce la mappa.
    static func makeMap(_ r: LEDLayoutImport.Result, hub: ControllerHub, name: String) -> CarMap {
        let plan = assignments(r, controllers: hub.controllers)
        var ids: [UUID] = []
        for a in plan {
            if var c = a.existing {
                if c.ledCount != a.addressCount || c.copiesPerPixel != a.branches {
                    c.ledCount = a.addressCount
                    c.copiesPerPixel = a.branches
                    hub.update(c)
                }
                ids.append(c.id)
            } else {
                ids.append(hub.addPlaceholder(name: "Pacco \(a.fileName)", ledCount: a.addressCount, copies: a.branches).id)
            }
        }
        let leds = r.points.map { p in
            PhysicalLED(key: LEDKey(controller: ids[p.controller], pixel: p.pixel), world: p.position,
                        confidence: 1, views: 0, part: p.zone, branch: p.branch)
        }
        var map = CarMap(name: name, leds: leds)
        map.source = "design"
        return map
    }
}
