import Foundation
import simd

/// Orologio di riproduzione: avanza solo mentre è in corsa, la pausa conserva la posizione.
/// Aprire o chiudere pannelli non lo tocca: solo play, pausa, ripresa e azzeramento lo cambiano.
struct PlaybackClock: Equatable {
    private(set) var position: Double = 0     // secondi di animazione
    private(set) var running = false
    var speed: Double = 1

    mutating func start() { position = 0; running = true }
    mutating func pause() { running = false }
    mutating func resume() { running = true }
    mutating func advance(_ dt: Double) {
        guard running, dt.isFinite, dt > 0 else { return }
        position += min(dt, 0.5) * (speed.isFinite ? max(0, speed) : 1)
    }
}

/// Lettera della centralina nella lista (A, B, C, …).
func controllerLetter(_ index: Int) -> String {
    guard index >= 0 else { return "?" }
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    return index < letters.count ? String(letters[index]) : "#\(index + 1)"
}

enum ControllerResolver {
    /// Centraline usate da anteprima ed effetti: quelle configurate, più segnaposto per ogni centralina
    /// citata dalla mappa ma non presente (es. profilo aperto senza centraline): così si lavora anche offline
    /// con i dati reali del profilo, senza rinumerare gli indirizzi.
    static func effective(_ controllers: [ControllerConfig], map: CarMap?) -> [ControllerConfig] {
        var list = controllers.sorted { $0.order < $1.order }
        guard let map else { return list }
        let known = Set(list.map { $0.id })
        var extra: [UUID: Int] = [:]
        var firstSeen: [UUID] = []
        for led in map.leds where !known.contains(led.key.controller) {
            if extra[led.key.controller] == nil { firstSeen.append(led.key.controller) }
            extra[led.key.controller] = max(extra[led.key.controller] ?? 0, led.key.pixel + 1)
        }
        for (i, id) in firstSeen.enumerated() {
            let n = list.count
            list.append(ControllerConfig(id: id, name: "Centralina \(controllerLetter(n)) (dalla mappa)", bleName: "", peripheralID: nil,
                                         ledCount: min(max(extra[id] ?? 1, 1), IdealProtocol.maxSafeLEDs), order: 1000 + i))
        }
        return list
    }
}

/// Origine delle posizioni mostrate (rispetta la mappa attiva).
enum MapSource: String {
    case none = "Nessuna mappa"
    case design = "Progetto"
    case scan = "Scansione"
    case demo = "Dimostrativa"

    init(_ map: CarMap?) {
        guard let map else { self = .none; return }
        self = map.isDemo ? .demo : (map.isDesign ? .design : .scan)
    }
}

/// Dati dell'inspector di un punto fisico toccato.
struct LEDInspection: Equatable {
    enum Branch: String { case left = "Sinistro", right = "Destro" }
    enum ZoneOrigin: String { case manual = "manuale", layout = "automatica · progetto", estimated = "automatica · stimata" }

    let ledID: UUID
    let twinID: UUID?
    let key: LEDKey
    let letter: String
    let controllerName: String
    let address: Int
    let branch: Branch
    let zone: AdaptiveEffects.Zone
    let origin: ZoneOrigin
    let rgb: RGB?
    let position: SIMD3<Double>
    let copies: Int

    var addressLabel: String { "\(letter)/\(address)" }

    static func make(map: CarMap, ledID: UUID, controllers: [ControllerConfig], colors: [LEDKey: RGB],
                     design: [LEDLayoutImport.Point]?) -> LEDInspection? {
        guard let led = map.leds.first(where: { $0.id == ledID }) else { return nil }
        let list = ControllerResolver.effective(controllers, map: map)
        let ci = list.firstIndex { $0.id == led.key.controller } ?? -1
        let p = map.carPosition(led)
        let same = map.leds.filter { $0.key == led.key }
        let twin = same.filter { $0.id != led.id }.min { simd_distance(map.carPosition($0), p) > simd_distance(map.carPosition($1), p) }
        let branch: Branch
        switch led.branch {
        case "left": branch = .left
        case "right": branch = .right
        default: branch = p.z <= 0 ? .left : .right     // sinistra = −z
        }
        let origin: ZoneOrigin = led.zoneOverride != nil ? .manual : (led.part.flatMap { AdaptiveEffects.Zone(rawValue: $0) } != nil ? .layout : .estimated)
        return LEDInspection(ledID: led.id, twinID: twin?.id, key: led.key, letter: controllerLetter(ci),
                             controllerName: ci >= 0 ? list[ci].name : "?", address: led.key.pixel, branch: branch,
                             zone: map.zone(of: led, design: design), origin: origin, rgb: colors[led.key], position: p, copies: same.count)
    }
}

/// Controllo dei gemelli a Y su una mappa reale: quanti indirizzi hanno più copie e quanto sono lontane.
/// Non presuppone simmetria: misura solo ciò che la mappa contiene.
struct TwinStats: Equatable {
    var addresses = 0          // indirizzi con almeno un punto
    var twins = 0              // indirizzi con 2+ copie
    var singles = 0
    var medianDistance = 0.0   // m
    var maxDistance = 0.0
    var farApart = 0           // copie oltre 0,5 m
    var differentZones = 0     // copie in zone diverse

    static func compute(_ map: CarMap, design: [LEDLayoutImport.Point]?) -> TwinStats {
        var groups: [LEDKey: [PhysicalLED]] = [:]
        for led in map.leds { groups[led.key, default: []].append(led) }
        var s = TwinStats()
        s.addresses = groups.count
        var dists: [Double] = []
        for (_, leds) in groups {
            guard leds.count > 1 else { s.singles += 1; continue }
            s.twins += 1
            var d = 0.0
            for i in 0..<leds.count { for j in (i + 1)..<leds.count { d = max(d, simd_distance(map.carPosition(leds[i]), map.carPosition(leds[j]))) } }
            dists.append(d)
            if d > 0.5 { s.farApart += 1 }
            if Set(leds.map { map.zone(of: $0, design: design) }).count > 1 { s.differentZones += 1 }
        }
        dists.sort()
        s.medianDistance = dists.isEmpty ? 0 : dists[dists.count / 2]
        s.maxDistance = dists.last ?? 0
        return s
    }
}
