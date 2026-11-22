import Foundation
import simd

/// Motore effetti indipendente dall'hardware: calcola il colore di ogni pixel logico nel tempo
/// dalle coordinate spaziali dei LED (sistema dell'auto). Lo stesso risultato alimenta
/// l'anteprima 3D e l'invio alle centraline.
enum EffectKind: String, Codable, CaseIterable, Identifiable {
    case solid, rainbow, waves, scanFrontBack, scanLeftRight, meteor, pulse, twinkle, powerOn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: return "Colore statico"
        case .rainbow: return "Arcobaleno"
        case .waves: return "Onde"
        case .scanFrontBack: return "Scansione avanti → dietro"
        case .scanLeftRight: return "Scansione sinistra → destra"
        case .meteor: return "Meteora"
        case .pulse: return "Pulsazione"
        case .twinkle: return "Scintillio"
        case .powerOn: return "Accensione progressiva"
        }
    }
    var icon: String {
        switch self {
        case .solid: return "circle.fill"
        case .rainbow: return "rainbow"
        case .waves: return "water.waves"
        case .scanFrontBack: return "arrow.left.and.right"
        case .scanLeftRight: return "arrow.up.and.down"
        case .meteor: return "sparkle"
        case .pulse: return "heart.fill"
        case .twinkle: return "sparkles"
        case .powerOn: return "power"
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
    }

    static func component(_ p: SIMD3<Double>, _ axis: EffectAxis) -> Double {
        switch axis {
        case .frontBack: return p.x      // 1 = davanti
        case .leftRight: return p.z      // 1 = sinistra
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
