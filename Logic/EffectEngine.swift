import Foundation
import simd

/// Motore effetti indipendente dall'hardware: calcola il colore di ogni pixel logico nel tempo
/// dalle coordinate spaziali dei LED (sistema dell'auto). Lo stesso risultato alimenta
/// l'anteprima 3D e l'invio alle centraline.
enum EffectCategory: String, CaseIterable, Identifiable {
    case base = "Base"
    case motion = "Movimento"
    case nature = "Natura"
    case party = "Festa"
    case car = "Auto"
    var id: String { rawValue }
}

enum EffectKind: String, Codable, CaseIterable, Identifiable {
    // Base
    case solid, gradient, colorCycle, breathe, pulse, heartbeat, strobe
    // Movimento
    case rainbow, gradientFlow, waves, scanFrontBack, scanLeftRight, bounce, dualScan, centerOut, outsideIn
    case colorWipe, meteor, rainbowMeteor, theaterChase, stripes, spiral, beacon, ripple, powerOn, powerDown
    // Natura
    case fire, candle, ocean, aurora, plasma, lava, rain, lightning, starfield
    // Festa
    case twinkle, sparkle, glitter, confetti, fireworks, police, checker, disco
    // Auto
    case turnSignal, hazard, welcome, brake

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid: return "Colore statico"
        case .gradient: return "Sfumatura"
        case .colorCycle: return "Ciclo colori"
        case .breathe: return "Respiro"
        case .pulse: return "Pulsazione"
        case .heartbeat: return "Battito"
        case .strobe: return "Stroboscopio"
        case .rainbow: return "Arcobaleno"
        case .gradientFlow: return "Sfumatura in movimento"
        case .waves: return "Onde"
        case .scanFrontBack: return "Scansione avanti → dietro"
        case .scanLeftRight: return "Scansione sinistra → destra"
        case .bounce: return "Supercar (avanti e indietro)"
        case .dualScan: return "Doppia scansione"
        case .centerOut: return "Dal centro verso l'esterno"
        case .outsideIn: return "Dall'esterno verso il centro"
        case .colorWipe: return "Passata di colori"
        case .meteor: return "Meteora"
        case .rainbowMeteor: return "Meteora arcobaleno"
        case .theaterChase: return "Inseguimento"
        case .stripes: return "Strisce"
        case .spiral: return "Spirale"
        case .beacon: return "Faro rotante"
        case .ripple: return "Cerchi nell'acqua"
        case .powerOn: return "Accensione progressiva"
        case .powerDown: return "Spegnimento progressivo"
        case .fire: return "Fuoco"
        case .candle: return "Candela"
        case .ocean: return "Oceano"
        case .aurora: return "Aurora boreale"
        case .plasma: return "Plasma"
        case .lava: return "Lava"
        case .rain: return "Pioggia"
        case .lightning: return "Fulmini"
        case .starfield: return "Cielo stellato"
        case .twinkle: return "Scintillio"
        case .sparkle: return "Brillantini"
        case .glitter: return "Glitter colorato"
        case .confetti: return "Coriandoli"
        case .fireworks: return "Fuochi d'artificio"
        case .police: return "Polizia"
        case .checker: return "Scacchiera"
        case .disco: return "Discoteca"
        case .turnSignal: return "Freccia sequenziale"
        case .hazard: return "Quattro frecce"
        case .welcome: return "Benvenuto"
        case .brake: return "Luci freno"
        }
    }

    var icon: String {
        switch self {
        case .solid: return "circle.fill"
        case .gradient: return "circle.lefthalf.filled"
        case .colorCycle: return "arrow.triangle.2.circlepath"
        case .breathe: return "wind"
        case .pulse: return "dot.radiowaves.left.and.right"
        case .heartbeat: return "heart.fill"
        case .strobe: return "bolt.fill"
        case .rainbow: return "rainbow"
        case .gradientFlow: return "water.waves.and.arrow.down"
        case .waves: return "water.waves"
        case .scanFrontBack: return "arrow.left.and.right"
        case .scanLeftRight: return "arrow.up.and.down"
        case .bounce: return "arrow.left.arrow.right"
        case .dualScan: return "arrow.left.and.line.vertical.and.arrow.right"
        case .centerOut: return "arrow.up.left.and.arrow.down.right"
        case .outsideIn: return "arrow.down.right.and.arrow.up.left"
        case .colorWipe: return "paintbrush"
        case .meteor: return "sparkle"
        case .rainbowMeteor: return "moon.stars.fill"
        case .theaterChase: return "ellipsis"
        case .stripes: return "line.3.horizontal"
        case .spiral: return "hurricane"
        case .beacon: return "light.beacon.max.fill"
        case .ripple: return "circle.circle"
        case .powerOn: return "power"
        case .powerDown: return "power.dotted"
        case .fire: return "flame.fill"
        case .candle: return "flame"
        case .ocean: return "drop.fill"
        case .aurora: return "sparkles.rectangle.stack"
        case .plasma: return "atom"
        case .lava: return "drop.triangle.fill"
        case .rain: return "cloud.rain.fill"
        case .lightning: return "cloud.bolt.fill"
        case .starfield: return "star.fill"
        case .twinkle: return "sparkles"
        case .sparkle: return "wand.and.stars"
        case .glitter: return "staroflife.fill"
        case .confetti: return "party.popper.fill"
        case .fireworks: return "fireworks"
        case .police: return "light.beacon.min.fill"
        case .checker: return "checkerboard.rectangle"
        case .disco: return "music.note"
        case .turnSignal: return "arrowshape.right.fill"
        case .hazard: return "exclamationmark.triangle.fill"
        case .welcome: return "hand.wave.fill"
        case .brake: return "car.rear.fill"
        }
    }

    var category: EffectCategory {
        switch self {
        case .solid, .gradient, .colorCycle, .breathe, .pulse, .heartbeat, .strobe: return .base
        case .rainbow, .gradientFlow, .waves, .scanFrontBack, .scanLeftRight, .bounce, .dualScan, .centerOut, .outsideIn,
             .colorWipe, .meteor, .rainbowMeteor, .theaterChase, .stripes, .spiral, .beacon, .ripple, .powerOn, .powerDown:
            return .motion
        case .fire, .candle, .ocean, .aurora, .plasma, .lava, .rain, .lightning, .starfield: return .nature
        case .twinkle, .sparkle, .glitter, .confetti, .fireworks, .police, .checker, .disco: return .party
        case .turnSignal, .hazard, .welcome, .brake: return .car
        }
    }

    /// Colori proposti quando si sceglie l'effetto.
    var defaultColors: [RGB] {
        let cyan = RGB(r: 0, g: 220, b: 245), black = RGB.black, white = RGB(r: 255, g: 255, b: 255)
        let amber = RGB(r: 255, g: 120, b: 0), red = RGB.red, blue = RGB.blue
        switch self {
        case .solid, .pulse, .waves, .scanFrontBack, .scanLeftRight, .dualScan, .meteor, .powerOn, .powerDown, .beacon, .ripple:
            return [cyan, black]
        case .gradient, .gradientFlow, .colorCycle, .colorWipe, .stripes, .spiral, .breathe, .confetti:
            return [RGB(r: 255, g: 0, b: 120), RGB(r: 120, g: 0, b: 255), cyan, RGB(r: 0, g: 255, b: 120)]
        case .heartbeat, .brake: return [red, black]
        case .strobe, .sparkle: return [white, RGB(r: 10, g: 10, b: 30)]
        case .bounce: return [red, black]
        case .centerOut, .outsideIn: return [cyan, RGB(r: 255, g: 0, b: 160), amber]
        case .theaterChase: return [amber, RGB(r: 20, g: 8, b: 0)]
        case .fire, .lava: return [RGB(r: 255, g: 40, b: 0), RGB(r: 255, g: 160, b: 0)]
        case .candle: return [RGB(r: 255, g: 140, b: 40), black]
        case .ocean: return [RGB(r: 0, g: 30, b: 140), RGB(r: 0, g: 190, b: 230), white]
        case .aurora: return [RGB(r: 0, g: 255, b: 120), RGB(r: 0, g: 160, b: 200), RGB(r: 160, g: 0, b: 255)]
        case .rain: return [RGB(r: 120, g: 170, b: 255), black]
        case .lightning: return [white, RGB(r: 10, g: 0, b: 40)]
        case .starfield: return [white, RGB(r: 0, g: 0, b: 25)]
        case .twinkle: return [white, RGB(r: 0, g: 40, b: 60)]
        case .police: return [red, blue]
        case .checker: return [white, RGB(r: 255, g: 0, b: 120)]
        case .turnSignal, .hazard: return [amber, black]
        case .welcome: return [cyan, white]
        case .rainbow, .rainbowMeteor, .plasma, .glitter, .fireworks, .disco: return [white, black]
        }
    }

    /// Effetti che usano tutti i colori della tavolozza (fino a 5).
    var usesPalette: Bool {
        switch self {
        case .gradient, .gradientFlow, .colorCycle, .colorWipe, .stripes, .spiral, .breathe, .confetti,
             .centerOut, .outsideIn, .ocean, .aurora: return true
        default: return false
        }
    }

    /// Effetti in cui i colori sono generati (arcobaleno, plasma…).
    var generatesColors: Bool {
        switch self {
        case .rainbow, .rainbowMeteor, .plasma, .glitter, .fireworks, .disco: return true
        default: return false
        }
    }
}

enum EffectAxis: String, Codable, CaseIterable, Identifiable {
    case frontBack, leftRight, bottomTop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .frontBack: return "Avanti–dietro"
        case .leftRight: return "Sinistra–destra"
        case .bottomTop: return "Basso–alto"
        }
    }
}

struct EffectParams: Codable, Equatable {
    var kind: EffectKind = .rainbow
    var colors: [RGB] = [RGB(r: 0, g: 220, b: 245), RGB(r: 0, g: 0, b: 0)]
    /// Cicli al secondo (0.02…3).
    var speed: Double = 0.4
    /// 0…1, scala tutti i colori.
    var intensity: Double = 0.8
    var axis: EffectAxis = .frontBack
    var reversed = false
    /// Larghezza relativa di onde, coda della meteora, fronte dell'accensione (0.05…1).
    var width: Double = 0.25

    var primary: RGB { colors.first ?? RGB(r: 255, g: 255, b: 255) }
    var secondary: RGB { colors.count > 1 ? colors[1] : .black }
}

struct EffectLayer: Codable, Identifiable, Equatable {
    var id = UUID()
    var zone: CarZone = .all
    /// Se impostato, il livello vale solo per questi pixel (selezione dell'editor).
    var keys: [LEDKey]?
    var params = EffectParams()
    var enabled = true
}

/// Programma: livelli applicati in ordine, i successivi sovrascrivono i precedenti nelle loro zone.
struct EffectProgram: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var layers: [EffectLayer]
    /// Colori fissi dipinti nell'editor, applicati sopra ai livelli.
    var paint: [LEDKey: RGB] = [:]
}

/// LED fisico per il motore: posizione nel sistema dell'auto.
struct EffectPoint: Equatable {
    var key: LEDKey
    var position: SIMD3<Double>
}

/// Dati precalcolati per un insieme di punti (coordinate normalizzate per asse, zone, hash).
struct EffectContext {
    let points: [EffectPoint]
    let u: [EffectAxis: [Double]]
    let zones: [CarZone]
    let hash: [Double]
    /// Coordinate normalizzate −1…1 rispetto all'ingombro dei LED (x avanti, y alto, z destra: sinistra = −z).
    let norm: [SIMD3<Double>]
    /// Distanza dal centro in pianta (0…1) e angolo attorno all'auto (0…1).
    let radius: [Double]
    let angle: [Double]

    init(points: [EffectPoint]) {
        self.points = points
        var u: [EffectAxis: [Double]] = [:]
        for axis in EffectAxis.allCases {
            let values = points.map { EffectContext.component($0.position, axis) }
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let span = max(hi - lo, 1e-6)
            u[axis] = values.map { ($0 - lo) / span }
        }
        self.u = u
        zones = points.map { ZoneClassifier.zone(of: $0.position) }
        hash = points.map { EffectContext.hash($0.key) }
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in points { lo = simd_min(lo, p.position); hi = simd_max(hi, p.position) }
        if points.isEmpty { lo = .zero; hi = .zero }
        let center = (lo + hi) / 2
        let half = simd_max((hi - lo) / 2, SIMD3<Double>(repeating: 1e-6))
        let n = points.map { ($0.position - center) / half }
        norm = n
        radius = n.map { min(1, (($0.x * $0.x + $0.z * $0.z) / 2).squareRoot()) }
        angle = n.map { EffectEngine.frac(atan2($0.z, $0.x) / (2 * .pi) + 1) }
    }

    static func component(_ p: SIMD3<Double>, _ axis: EffectAxis) -> Double {
        switch axis {
        case .frontBack: return p.x      // 1 = davanti
        case .leftRight: return -p.z     // 1 = sinistra
        case .bottomTop: return p.y
        }
    }

    /// Valore pseudo-casuale stabile in [0, 1) per pixel (lo scintillio è ripetibile).
    static func hash(_ key: LEDKey) -> Double {
        var h: UInt64 = 1469598103934665603
        for b in key.controller.uuidString.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        h = (h ^ UInt64(truncatingIfNeeded: key.pixel)) &* 1099511628211
        h ^= h >> 29
        return Double(h % 1_000_000) / 1_000_000
    }
}

enum EffectEngine {
    /// Colore di ogni pixel logico al tempo `time` (secondi). Se un pixel ha più posizioni fisiche
    /// (cablaggio a Y) il colore è la media: l'hardware non può distinguerle.
    static func render(_ program: EffectProgram, context: EffectContext, time: Double) -> [LEDKey: RGB] {
        var perPoint = [RGB](repeating: .black, count: context.points.count)
        for layer in program.layers where layer.enabled {
            let keySet: Set<LEDKey>? = layer.keys.map { Set($0) }
            for i in context.points.indices {
                if let keySet, !keySet.contains(context.points[i].key) { continue }
                if layer.zone != .all && context.zones[i] != layer.zone { continue }
                perPoint[i] = color(layer.params, context: context, index: i, time: time)
            }
        }
        var sums: [LEDKey: (Double, Double, Double, Int)] = [:]
        for (i, p) in context.points.enumerated() {
            let c = program.paint[p.key] ?? perPoint[i]
            let s = sums[p.key] ?? (0, 0, 0, 0)
            sums[p.key] = (s.0 + Double(c.r), s.1 + Double(c.g), s.2 + Double(c.b), s.3 + 1)
        }
        var out: [LEDKey: RGB] = [:]
        for (k, s) in sums {
            let n = Double(max(s.3, 1))
            out[k] = RGB(r: UInt8((s.0 / n).rounded()), g: UInt8((s.1 / n).rounded()), b: UInt8((s.2 / n).rounded()))
        }
        return out
    }

    static func color(_ p: EffectParams, context: EffectContext, index i: Int, time t: Double) -> RGB {
        let axis: EffectAxis
        switch p.kind {
        case .scanFrontBack: axis = .frontBack
        case .scanLeftRight: axis = .leftRight
        default: axis = p.axis
        }
        var u = context.u[axis]?[i] ?? 0
        if p.reversed { u = 1 - u }
        let speed = min(max(p.speed, 0.0), 3)
        let w = min(max(p.width, 0.05), 1)
        let level: Double
        var base = p.primary
        var background = p.secondary
        switch p.kind {
        case .solid:
            return scale(p.primary, p.intensity)
        case .rainbow:
            let hue = frac(u * w * 4 + t * speed)
            return scale(hsv(hue, 1, 1), p.intensity)
        case .waves:
            level = 0.5 + 0.5 * sin(2 * Double.pi * (u / w - t * speed))
        case .scanFrontBack, .scanLeftRight:
            let head = frac(t * speed) * (1 + 2 * w) - w
            level = max(0, 1 - abs(u - head) / w)
        case .meteor:
            let head = frac(t * speed) * (1 + w)
            let d = head - u
            level = (d >= 0 && d <= w) ? pow(1 - d / w, 2) : 0
        case .pulse:
            level = 0.5 - 0.5 * cos(2 * Double.pi * t * speed)
        case .twinkle:
            let phase = frac(t * speed + context.hash[i] * 7.31)
            let spark = w * 0.5
            level = phase < spark ? 1 - phase / spark : 0
            background = scale(p.secondary, 0.6)
        case .powerOn:
            let progress = min(1, t * speed)
            level = min(1, max(0, (progress * (1 + w) - u) / w))
            background = .black
            base = p.primary
        default:
            return scale(extended(p, context: context, index: i, time: t, u: u, speed: speed, width: w), p.intensity)
        }
        return scale(mix(background, base, level), p.intensity)
    }

    // MARK: Colore

    static func frac(_ x: Double) -> Double { x - floor(x) }

    static func scale(_ c: RGB, _ k: Double) -> RGB {
        let f = min(max(k, 0), 1)
        return RGB(r: UInt8((Double(c.r) * f).rounded()), g: UInt8((Double(c.g) * f).rounded()), b: UInt8((Double(c.b) * f).rounded()))
    }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let k = min(max(t, 0), 1)
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) * (1 - k) + Double(y) * k).rounded()) }
        return RGB(r: m(a.r, b.r), g: m(a.g, b.g), b: m(a.b, b.b))
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        let hh = frac(h) * 6
        let i = Int(hh) % 6
        let f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        var r = v, g = t, b = p
        switch i {
        case 0: r = v; g = t; b = p
        case 1: r = q; g = v; b = p
        case 2: r = p; g = v; b = t
        case 3: r = p; g = q; b = v
        case 4: r = t; g = p; b = v
        default: r = v; g = p; b = q
        }
        return RGB(r: UInt8((r * 255).rounded()), g: UInt8((g * 255).rounded()), b: UInt8((b * 255).rounded()))
    }

    /// Gradiente lineare lungo un asse sui pixel indicati.
    static func gradient(keys: Set<LEDKey>, context: EffectContext, axis: EffectAxis, from a: RGB, to b: RGB) -> [LEDKey: RGB] {
        guard let us = context.u[axis] else { return [:] }
        var sel: [(LEDKey, Double)] = []
        for (i, p) in context.points.enumerated() where keys.contains(p.key) { sel.append((p.key, us[i])) }
        guard let lo = sel.map({ $0.1 }).min(), let hi = sel.map({ $0.1 }).max() else { return [:] }
        let span = max(hi - lo, 1e-6)
        var sums: [LEDKey: (Double, Int)] = [:]
        for (k, u) in sel { let s = sums[k] ?? (0, 0); sums[k] = (s.0 + (u - lo) / span, s.1 + 1) }
        return sums.mapValues { mix(a, b, $0.0 / Double($0.1)) }
    }
}
