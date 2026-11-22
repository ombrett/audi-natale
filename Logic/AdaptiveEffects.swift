import Foundation

/// Le 60 animazioni come funzioni di tempo e posizione (porting fedele di Effetti_Adattivi.py):
/// si calcolano sui punti della mappa attiva, quindi seguono la scansione reale dell'auto.
/// Coordinate: spazio del modello GLB in metri, +X verso il muso, +Y verso l'alto.
enum AdaptiveEffects {
    typealias C = SIMD3<Double>

    enum Zone: String, CaseIterable, Codable {
        case paraurti_anteriore, cofano, montante_anteriore, tetto, montante_centrale
        case fiancata_anteriore, fiancata_posteriore, montante_posteriore, portellone

        var order: Int { Zone.allCases.firstIndex(of: self)! }
        var isSide: Bool { self == .fiancata_anteriore || self == .fiancata_posteriore || self == .paraurti_anteriore || self == .portellone }
        var isPillar: Bool { rawValue.hasPrefix("montante") }

        var label: String {
            switch self {
            case .paraurti_anteriore: return "Paraurti anteriore"
            case .cofano: return "Cofano"
            case .montante_anteriore: return "Montante anteriore"
            case .tetto: return "Tetto"
            case .montante_centrale: return "Montante centrale"
            case .fiancata_anteriore: return "Fiancata anteriore"
            case .fiancata_posteriore: return "Fiancata posteriore"
            case .montante_posteriore: return "Montante posteriore"
            case .portellone: return "Portellone"
            }
        }
    }

    /// Un punto fisico: x 0…1 da dietro a davanti, h altezza normalizzata, r distanza dal piano centrale,
    /// i indice globale dell'indirizzo (serve agli effetti "casuali" stabili), zona della carrozzeria.
    struct Sample: Equatable {
        var x: Double
        var h: Double
        var r: Double
        var i: Int
        var zone: Zone
    }

    typealias Effect = (Double, Sample) -> C

    struct Preset: Identifiable {
        let id: String
        let name: String
        let duration: Double
        let loop: Bool
        let effect: Effect
    }

    // MARK: Utilità (stessa aritmetica del riferimento Python)

    static let tau = 2 * Double.pi
    static let cyan = C(11, 145, 255), ice = C(151, 224, 255), violet = C(126, 27, 245)
    static let amber = C(255, 89, 10), warm = C(255, 184, 72)
    static let gold = C(255, 163, 29), ruby = C(255, 12, 27), mint = C(31, 239, 144), pink = C(255, 39, 129)

    /// Resto come l'operatore % di Python sui float (segno del divisore).
    @inline(__always) static func pmod(_ a: Double, _ b: Double) -> Double {
        var m = fmod(a, b)
        if m != 0 && ((b < 0) != (m < 0)) { m += b }
        return m
    }
    @inline(__always) static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let v = max(0, min(1, (x - a) / (b - a)))
        return v * v * (3 - 2 * v)
    }
    @inline(__always) static func bell(_ x: Double, _ w: Double) -> Double { let q = x / w; return exp(-(q * q)) }
    @inline(__always) static func cyc(_ p: Double) -> Double { (1 + cos(tau * p)) / 2 }
    @inline(__always) static func pulse(_ t: Double, _ s: Double, _ e: Double, _ edge: Double = 0.05) -> Double {
        smooth(s, s + edge, t) * (1 - smooth(e - edge, e, t))
    }
    @inline(__always) static func pw(_ b: Double, _ n: Double) -> Double { pow(b, n) }
    @inline(__always) static func s(_ c: C, _ k: Double) -> C { c * k }
    /// Somma, arrotonda (metà al pari, come round() di Python) e limita a 0…255.
    static func add(_ cs: C...) -> C {
        var t = C(0, 0, 0)
        for c in cs { t += c }
        return C(max(0, min(255, t.x.rounded(.toNearestOrEven))), max(0, min(255, t.y.rounded(.toNearestOrEven))),
                 max(0, min(255, t.z.rounded(.toNearestOrEven))))
    }
    static func fi(_ i: Int) -> Double { Double(i) }

    // MARK: Effetti

    static func ignition(_ u: Double, _ p: Sample) -> C {
        let front = 1.13 - 1.29 * smooth(0.025, 0.65, u)
        let hold = smooth(0.15, 0.80, u)
        return add(s(ice, 0.98 * bell(p.x - front, 0.040) * (1 - smooth(0.58, 0.78, u))),
                   s(cyan, 0.21 * smooth(-0.06, 0.05, p.x - front) * smooth(0, 0.12, u) + 0.17 * hold))
    }
    static func scan(_ u: Double, _ p: Sample) -> C {
        let center = 0.5 + 0.68 * cos(tau * u)
        return add(s(violet, 0.052 + 0.21 * bell(p.x - center + 0.115, 0.115)),
                   s(ice, 0.93 * bell(p.x - center, 0.025)),
                   s(cyan, 0.50 * bell(p.x - center, 0.072)))
    }
    static func ember(_ u: Double, _ p: Sample) -> C {
        let phase = tau * (u - 1.22 * p.h - 0.66 * p.x)
        let band = pw(0.5 + 0.5 * sin(phase), 3)
        let second = pw(0.5 + 0.5 * sin(2 * phase + fi(p.i) * 0.618), 8)
        return add(s(amber, 0.06 + 0.61 * band), s(warm, 0.29 * band * second))
    }
    static func aurora(_ u: Double, _ p: Sample) -> C {
        let phase = tau * (u + p.x * 0.78 - p.h * 0.64 + p.r * 0.52)
        let blend = 0.5 + 0.5 * sin(phase)
        let pul = 0.35 + 0.65 * (0.5 + 0.5 * cos(phase * 2))
        let mint = C(15, 232, 142)
        return add(s(mint, 0.69 * pul * blend), s(violet, 0.60 * pul * (1 - blend)))
    }
    static func rain(_ u: Double, _ p: Sample) -> C {
        let shift = pmod(fi(p.i) * 0.61803398875, 1)
        let phase = pmod(2 * u + p.h * 0.83 + shift, 1)
        let streak = bell(min(phase, 1 - phase), 0.075)
        return add(s(cyan, 0.055), s(ice, 0.86 * streak))
    }
    static func warmStart(_ u: Double, _ p: Sample) -> C {
        let a = smooth(p.x * 0.58, p.x * 0.58 + 0.23, u)
        let edge = bell(u - p.x * 0.58 - 0.10, 0.048)
        return add(s(gold, 0.26 * a), s(warm, 0.70 * edge))
    }
    static func shutdown(_ u: Double, _ p: Sample) -> C {
        let edge = 1.11 - 1.24 * smooth(0.14, 0.84, u)
        let live = smooth(-0.035, 0.035, edge - p.x)
        return add(s(violet, 0.29 * live * (1 - smooth(0.84, 1, u))),
                   s(pink, 0.72 * bell(p.x - edge, 0.044) * pulse(u, 0.08, 0.89)))
    }
    static func comet(_ u: Double, _ p: Sample) -> C {
        let q = pmod(2 * u - p.x + 0.16 * p.h, 1)
        return add(s(cyan, 0.43 * exp(-q * 7)), s(ice, 0.92 * bell(min(q, 1 - q), 0.037)))
    }
    static func goldenTide(_ u: Double, _ p: Sample) -> C {
        let a = pw(cyc(u + p.x * 0.72 - p.h * 0.97), 3)
        let b = pw(cyc(2 * u - p.x * 0.64 + p.h * 0.66), 6)
        return add(s(gold, 0.065 + 0.61 * a), s(warm, 0.39 * a * b))
    }
    static func eclipse(_ u: Double, _ p: Sample) -> C {
        let a = cyc(u + 0.65 * p.x - 0.88 * p.r)
        let edge = bell(a - 0.52, 0.115)
        return add(s(violet, 0.07 + 0.42 * edge), s(pink, 0.38 * edge * cyc(u + p.h)))
    }
    static func carbon(_ u: Double, _ p: Sample) -> C {
        let q = pw(cyc(u + p.x * 1.65 + p.h * 0.58), 8)
        return add(s(ruby, 0.069 + 0.87 * q), s(amber, 0.28 * q * cyc(u - p.h)))
    }
    static func neonGrid(_ u: Double, _ p: Sample) -> C {
        let a = pw(cyc(u * 2 - p.x * 3.1), 9)
        let b = pw(cyc(u + p.h * 2.25), 14)
        return add(s(cyan, 0.08 + 0.70 * a), s(pink, 0.08 + 0.63 * b))
    }
    static func tidal(_ u: Double, _ p: Sample) -> C {
        let a = cyc(u - p.x * 0.38 - p.h * 0.78 + p.r * 0.69)
        let b = cyc(u + p.h * 0.28 - p.r * 0.58)
        return add(s(cyan, 0.07 + 0.58 * a * a), s(mint, 0.46 * b * b * b))
    }
    static func ultraviolet(_ u: Double, _ p: Sample) -> C {
        let q = cyc(u - p.r * 1.18 + p.h * 0.54)
        let edge = bell(q - 0.46, 0.14)
        return add(s(violet, 0.14 + 0.85 * q * q * q), s(ice, 0.28 * edge))
    }
    static func crystal(_ u: Double, _ p: Sample) -> C {
        let window = pmod(u + pmod(fi(p.i) * 0.754877666, 1), 1)
        let glint = bell(window - 0.45, 0.055)
        return add(s(ice, 0.10 + 0.71 * glint), s(violet, 0.18 * cyc(u + p.x)))
    }
    static func citrus(_ u: Double, _ p: Sample) -> C {
        let a = cyc(u + p.r * 1.75 - p.x * 0.71 + p.h * 0.21)
        return add(s(mint, 0.12 + 0.56 * a * a), s(gold, 0.70 * pw(1 - a, 3)))
    }
    static func orbit(_ u: Double, _ p: Sample) -> C {
        let px = 0.5 + 0.49 * cos(tau * u)
        let pr = 0.46 + 0.51 * sin(tau * u)
        let a = bell(p.x - px, 0.21) * bell(p.r - pr, 0.26)
        let b = bell(p.x - (1 - px), 0.18) * bell(p.r - (0.92 - pr), 0.25)
        return add(s(violet, 0.10 + 0.57 * b), s(cyan, 0.76 * a))
    }
    static func heartbeat(_ u: Double, _ p: Sample) -> C {
        let q = pmod(u - 0.12 * abs(p.x - 0.5), 1)
        let k = bell(q - 0.22, 0.057) + 0.55 * bell(q - 0.40, 0.072)
        return add(s(ruby, 0.13 + 0.68 * k), s(warm, 0.18 * k))
    }
    static func city(_ u: Double, _ p: Sample) -> C {
        let ramp = cyc(u + p.x * 0.62 + 0.15 * p.h)
        let spark = pw(cyc(2 * u - p.x * 2.4 + p.r * 0.53), 9)
        return add(s(pink, 0.10 + 0.49 * ramp), s(cyan, 0.12 + 0.43 * (1 - ramp)), s(ice, 0.20 * spark))
    }
    static func galaxy(_ u: Double, _ p: Sample) -> C {
        let a = pw(cyc(u + p.x * 0.96 + p.h * 0.59 + p.r * 0.72), 4)
        let b = bell(pmod(u + pmod(fi(p.i) * 0.41421356, 1), 1) - 0.5, 0.05)
        return add(s(violet, 0.12 + 0.58 * a), s(cyan, 0.23 * (1 - a)), s(ice, 0.70 * b))
    }
    static func collision(_ u: Double, _ p: Sample) -> C {
        let merge = smooth(0, 0.42, u)
        let gap = 0.58 * (1 - merge)
        let fronts = bell(p.x - 0.5 + gap, 0.057) + bell(p.x - 0.5 - gap, 0.057)
        let strike = bell(u - 0.43, 0.062) * bell(p.x - 0.5, 0.087)
        let radius = 0.58 * smooth(0.43, 0.94, u)
        let rebound = bell(abs(p.x - 0.5) - radius, 0.050) * pulse(u, 0.43, 0.99, 0.09)
        return add(s(cyan, 0.76 * fronts * (1 - smooth(0.38, 0.49, u)) * smooth(0, 0.06, u)),
                   s(ice, 0.85 * strike), s(pink, 0.82 * rebound))
    }
    static func blueprint(_ u: Double, _ p: Sample) -> C {
        let start = Double(p.zone.order) * 0.073
        let rise = smooth(start, start + 0.12, u)
        let highlight = bell(u - start - 0.08, 0.035)
        return add(s(cyan, 0.25 * rise), s(ice, 0.63 * highlight))
    }
    static func retroArcade(_ u: Double, _ p: Sample) -> C {
        let colors = [C(46, 220, 204), C(174, 51, 255), C(250, 94, 27), C(255, 170, 53)]
        let phase = pmod(u - p.x * 0.80 - p.h * 0.30, 1) * 4
        let k = min(3, Int(phase))
        let t = smooth(0.68, 1, phase - Double(k))
        return add(s(colors[k], 0.65 * (1 - t)), s(colors[(k + 1) % 4], 0.65 * t))
    }
    static func pillarsToRoof(_ u: Double, _ p: Sample) -> C {
        if p.zone == .tetto { return add(s(ice, 0.15 + 0.58 * pw(cyc(u - p.x * 0.81), 7))) }
        if p.zone.isPillar {
            let arc = pw(cyc(u - p.h * 0.87 + p.x * 0.48), 5)
            return add(s(cyan, 0.08 + 0.84 * arc), s(violet, 0.15))
        }
        return add(s(violet, 0.13 + 0.14 * pw(cyc(u - p.x), 3)))
    }
    static func checkered(_ u: Double, _ p: Sample) -> C {
        let travel = 2 * u * tau
        let stripe = cos(tau * p.x * 5 - travel) * cos(tau * p.h * 3)
        let light = smooth(-0.14, 0.14, stripe)
        return add(s(C(209, 223, 255), 0.68 * light), s(C(34, 53, 101), 0.26 * (1 - light)))
    }
    static func blueHour(_ u: Double, _ p: Sample) -> C {
        let a = cyc(u - p.h * 0.97)
        let b = cyc(u + p.x * 0.75)
        return add(s(C(17, 55, 255), 0.16 + 0.39 * a), s(C(81, 238, 242), 0.43 * b * b * (1 - a)))
    }
    static func twinTrails(_ u: Double, _ p: Sample) -> C {
        let q1 = pmod(u - p.x, 1)
        let q2 = pmod(u + p.x - 0.5, 1)
        let a = exp(-q1 * 8) * smooth(0, 0.018, 1 - q1)
        let b = exp(-q2 * 8) * smooth(0, 0.018, 1 - q2)
        return add(s(cyan, 0.76 * a), s(gold, 0.70 * b), s(violet, 0.09))
    }
    static func meteor(_ u: Double, _ p: Sample) -> C {
        let a = bell(pmod(u - p.x * 0.33 + p.h * 0.67, 1) - 0.5, 0.037)
        let b = bell(pmod(u - p.x * 0.33 + p.h * 0.67 - 0.24, 1) - 0.5, 0.085)
        let c = cyc(u + p.x * 0.67)
        return add(s(ice, 0.82 * a), s(violet, 0.48 * b), s(C(16, 46, 178), 0.10 + 0.12 * c))
    }
    static func theater(_ u: Double, _ p: Sample) -> C {
        let wave = cyc(u + p.x * 0.45)
        let lit = smooth(0.18, 0.52, p.h + 0.18 * wave)
        let spark = bell(pmod(u + fi(p.i) * 0.381966, 1) - 0.5, 0.040)
        return add(s(C(139, 31, 255), 0.25 * lit), s(C(255, 175, 92), 0.62 * spark * lit),
                   s(C(255, 54, 102), 0.28 * pw(cyc(u - p.x), 5)))
    }
    static func sunsetExit(_ u: Double, _ p: Sample) -> C {
        let cutoff = 1.13 - 1.29 * smooth(0.10, 0.89, u)
        let lit = smooth(-0.04, 0.09, cutoff - p.x)
        let edge = bell(p.x - cutoff, 0.065) * pulse(u, 0.07, 0.95, 0.11)
        return add(s(C(193, 35, 103), 0.39 * lit * (1 - smooth(0.79, 0.99, u))), s(C(255, 124, 21), 0.70 * edge))
    }
    static func pinstripe(_ u: Double, _ p: Sample) -> C {
        let allowed: Double = p.zone.isSide ? 1 : 0
        return add(s(ice, 0.66 * allowed * bell(p.h - 0.29, 0.083) * (0.28 + 0.72 * pw(cyc(u - p.x * 0.62), 3))),
                   s(cyan, 0.23 * allowed * bell(p.h - 0.34, 0.14)))
    }
    static func sillRun(_ u: Double, _ p: Sample) -> C {
        let a = bell(pmod(u + p.x, 1) - 0.50, 0.12)
        let c = p.zone.isSide ? bell(p.h - 0.07, 0.096) : 0
        return add(s(mint, c * (0.20 + 0.68 * a)), s(ice, c * 0.17 * a * a))
    }
    static func wheelHalo(_ u: Double, _ p: Sample) -> C {
        let d = min(hypot((p.x - 0.185) * 3.9, p.h * 1.2), hypot((p.x - 0.835) * 3.9, p.h * 1.2))
        let a = p.zone.isSide ? bell(d - 0.37, 0.105) : 0
        return add(s(violet, a * (0.43 + 0.35 * cyc(u + p.x))), s(ice, a * 0.20 * cyc(2 * u - p.x)))
    }
    static func roofRays(_ u: Double, _ p: Sample) -> C {
        if p.zone != .tetto { return add(s(violet, 0.05)) }
        return add(s(gold, 0.12 + 0.64 * pw(cyc(u - p.r * 2.1 + p.x * 0.45), 7)), s(pink, 0.29 * cyc(u + p.r * 0.83)))
    }
    static func tailFan(_ u: Double, _ p: Sample) -> C {
        if p.zone != .portellone { return add(s(ruby, 0.055)) }
        let d = atan2(p.h - 0.10, max(0.02, p.r))
        return add(s(ruby, 0.19 + 0.65 * pw(cyc(u + d * 0.71), 6)), s(warm, 0.31 * pw(cyc(u - p.r * 1.4), 6)))
    }
    static func bonnetFan(_ u: Double, _ p: Sample) -> C {
        if p.zone != .cofano { return add(s(cyan, 0.055)) }
        let d = atan2(p.r, p.x - 0.72)
        return add(s(ice, 0.13 + 0.74 * pw(cyc(u + d * 0.68), 7)), s(mint, 0.23 * cyc(u + p.r)))
    }
    static func glassFrame(_ u: Double, _ p: Sample) -> C {
        if p.zone.isPillar { return add(s(ice, 0.28 + 0.58 * pw(cyc(u - p.h + p.x * 0.32), 6))) }
        let weight = p.zone == .tetto ? 0.35 : 0.10
        return add(s(cyan, weight * cyc(u + p.x * 0.66)))
    }
    static func rapidTrace(_ u: Double, _ p: Sample) -> C {
        let a = (Double(p.zone.order) + 0.61 * (0.5 + 0.5 * cos(p.x * 7 + p.h * 5))) / 9
        let width = bell(pmod(u - a, 1) - 0.08, 0.09)
        return add(s(mint, 0.82 * width), s(cyan, 0.21 * bell(pmod(u - a, 1) - 0.18, 0.17)))
    }
    static func flareArch(_ u: Double, _ p: Sample) -> C {
        let center = u < 0.5 ? 0.21 : 0.82
        let d = hypot((p.x - center) * 3.9, p.h * 1.2)
        let a = bell(d - (0.2 + pmod(0.5 * u, 0.25) * 1.28), 0.12) * pw(sin(tau * u), 2)
        return add(s(gold, 0.77 * a), s(amber, 0.08 + 0.30 * a))
    }
    static func panels(_ u: Double, _ p: Sample) -> C {
        let step = p.zone.order
        let parity = Double(step % 2)
        return add(s(violet, 0.12 + 0.61 * pw(cyc(u + 0.5 * parity), 5)), s(ice, 0.23 * pw(cyc(u + Double(step) * 0.22), 9)))
    }
    static func zipper(_ u: Double, _ p: Sample) -> C {
        let phase = pmod(u + p.x * 0.80, 1)
        let rows = Int(floor(p.h * 13))
        let parity = Double(((rows % 2) + 2) % 2)
        let gate = pw(cyc(phase + 0.5 * parity), 8)
        return add(s(gold, 0.73 * gate), s(pink, 0.16 * cyc(u - p.x)))
    }
    static func outward(_ u: Double, _ p: Sample) -> C {
        let q = pmod(u - abs(p.x - 0.5) * 1.54, 1)
        return add(s(mint, 0.80 * bell(q - 0.07, 0.051)), s(cyan, 0.29 * bell(q - 0.17, 0.105)))
    }
    static func fold(_ u: Double, _ p: Sample) -> C {
        let q = pmod(u + abs(p.x - 0.5) * 1.36 + p.h * 0.30, 1)
        return add(s(violet, 0.55 * bell(q - 0.16, 0.135)), s(ice, 0.71 * bell(q - 0.07, 0.034)))
    }
    static func rainUp(_ u: Double, _ p: Sample) -> C {
        let q = pmod(2 * u - p.h * 0.88 + pmod(fi(p.i) * 0.328117, 1), 1)
        return add(s(mint, 0.76 * bell(q - 0.45, 0.062)), s(cyan, 0.17 * bell(q - 0.34, 0.15)))
    }
    static func laserDrift(_ u: Double, _ p: Sample) -> C {
        let a = pmod(u + p.r * 1.29 - p.x * 0.63, 1)
        let b = pmod(u - p.r * 0.80 + p.h * 0.69, 1)
        return add(s(ruby, 0.85 * bell(a - 0.50, 0.029)), s(violet, 0.54 * bell(b - 0.48, 0.077)))
    }
    static func moire(_ u: Double, _ p: Sample) -> C {
        let v = cos(tau * (2 * u - 2.7 * p.x + p.h * 2.5)) * sin(tau * (u + 2.4 * p.r + 1.8 * p.x))
        return add(s(pink, 0.70 * pw(max(v, 0), 2)), s(ice, 0.68 * pw(max(-v, 0), 2)))
    }
    static func slowMagma(_ u: Double, _ p: Sample) -> C {
        let v = cyc(u - p.x * 0.75 - p.h * 0.99 + sin(p.r * 7) * 0.17)
        return add(s(ruby, 0.10 + 0.58 * v), s(gold, 0.69 * pw(v, 9)))
    }
    static func paperLantern(_ u: Double, _ p: Sample) -> C {
        let a = cyc(u - p.h * 0.34 + p.x * 0.27)
        let b = cyc(2 * u - p.x * 1.19 - p.r * 0.58)
        return add(s(warm, 0.13 + 0.50 * a), s(C(255, 51, 100), 0.37 * b * b * (1 - a)))
    }
    static func snowField(_ u: Double, _ p: Sample) -> C {
        let q = pmod(u * 3 + p.h * 0.85 + fi(p.i) * 0.7237, 1)
        let c = cyc(u + p.x * 0.6)
        return add(s(ice, 0.13 + 0.77 * bell(q - 0.50, 0.036)), s(cyan, 0.20 * c))
    }
    static func prismatic(_ u: Double, _ p: Sample) -> C {
        let q = u + p.h * 0.47 + p.x * 0.57
        return add(s(amber, 0.73 * pw(cyc(q), 4)), s(mint, 0.71 * pw(cyc(q + 1.0 / 3), 4)), s(violet, 0.79 * pw(cyc(q + 2.0 / 3), 4)))
    }
    static func montage(_ seq: [Effect]) -> Effect {
        { u, p in
            let n = Double(seq.count)
            let pos = min(u * n, n - 1e-8)
            let stage = Int(pos)
            let local = pos - Double(stage)
            let next = seq[(stage + 1) % seq.count]
            let current = seq[stage](local, p)
            let dissolve = smooth(0.77, 1, local)
            if dissolve == 0 { return current }
            let incoming = next(pmod((local - 1) * 0.23, 1), p)
            return add(s(current, 1 - dissolve), s(incoming, dissolve))
        }
    }
    static func brandedIntro(_ u: Double, _ p: Sample) -> C {
        let bodywave = bell(p.x - (1.17 - 1.33 * smooth(0.06, 0.73, u)), 0.060)
        let shape = p.zone.isPillar ? 1 : 0.23
        return add(s(ice, 0.77 * bodywave * pulse(u, 0.06, 0.80, 0.12)), s(gold, 0.40 * shape * smooth(0.56, 0.80, u)),
                   s(cyan, 0.15 * smooth(0.31, 0.69, u)))
    }
    static func sendoff(_ u: Double, _ p: Sample) -> C {
        let ring = bell(p.h - (0.92 - 1.05 * smooth(0.16, 0.88, u)), 0.075)
        return add(s(violet, 0.39 * (1 - smooth(0.14, 0.79, u))), s(pink, 0.77 * ring * pulse(u, 0.14, 0.94, 0.10)))
    }
    static func landmark(_ u: Double, _ p: Sample) -> C {
        let k = Double(p.zone.order)
        let a = bell(pmod(u - k / 9, 1) - 0.09, 0.067)
        let b = bell(pmod(u - (8 - k) / 9, 1) - 0.31, 0.08)
        return add(s(mint, 0.76 * a), s(pink, 0.65 * b), s(violet, 0.07))
    }

    static let presets: [Preset] = [
        Preset(id: "ignition_sweep", name: "Accensione a cascata", duration: 2.5, loop: false, effect: ignition),
        Preset(id: "ice_scan", name: "Scanner Ghiaccio", duration: 3.5, loop: true, effect: scan),
        Preset(id: "ember_flow", name: "Brace", duration: 4, loop: true, effect: ember),
        Preset(id: "aurora", name: "Aurora", duration: 5, loop: true, effect: aurora),
        Preset(id: "diamond_rain", name: "Pioggia di diamanti", duration: 4, loop: true, effect: rain),
        Preset(id: "golden_welcome", name: "Benvenuto Ambra", duration: 3.0, loop: false, effect: warmStart),
        Preset(id: "night_shutdown", name: "Spegnimento Viola", duration: 2.7, loop: false, effect: shutdown),
        Preset(id: "blue_comet", name: "Cometa Blu", duration: 4.0, loop: true, effect: comet),
        Preset(id: "golden_tide", name: "Marea Dorata", duration: 5.0, loop: true, effect: goldenTide),
        Preset(id: "eclipse", name: "Eclissi", duration: 5.5, loop: true, effect: eclipse),
        Preset(id: "redline", name: "Redline", duration: 4.0, loop: true, effect: carbon),
        Preset(id: "neon_grid", name: "Griglia Neon", duration: 4.0, loop: true, effect: neonGrid),
        Preset(id: "tidal", name: "Atlantico", duration: 6.0, loop: true, effect: tidal),
        Preset(id: "ultraviolet", name: "Ultravioletto", duration: 5.0, loop: true, effect: ultraviolet),
        Preset(id: "crystal", name: "Cristalli", duration: 5.0, loop: true, effect: crystal),
        Preset(id: "citrus", name: "Lime Elettrico", duration: 4.5, loop: true, effect: citrus),
        Preset(id: "orbit", name: "Orbita", duration: 5.0, loop: true, effect: orbit),
        Preset(id: "heartbeat", name: "Battito Rosso", duration: 3.6, loop: true, effect: heartbeat),
        Preset(id: "night_city", name: "Città Neon", duration: 5.0, loop: true, effect: city),
        Preset(id: "galaxy", name: "Galassia", duration: 6.0, loop: true, effect: galaxy),
        Preset(id: "collision", name: "Collisione", duration: 3.1, loop: false, effect: collision),
        Preset(id: "blueprint", name: "Blueprint", duration: 4.0, loop: false, effect: blueprint),
        Preset(id: "retro_arcade", name: "Arcade 16-bit", duration: 5.0, loop: true, effect: retroArcade),
        Preset(id: "pillars_to_roof", name: "Montanti in salita", duration: 4.5, loop: true, effect: pillarsToRoof),
        Preset(id: "checkered", name: "Scacchiera Racing", duration: 4.0, loop: true, effect: checkered),
        Preset(id: "blue_hour", name: "Ora Blu", duration: 7.0, loop: true, effect: blueHour),
        Preset(id: "twin_trails", name: "Doppia Scia", duration: 4.5, loop: true, effect: twinTrails),
        Preset(id: "meteor", name: "Meteorite", duration: 4.0, loop: true, effect: meteor),
        Preset(id: "theater", name: "Première", duration: 6.0, loop: true, effect: theater),
        Preset(id: "sunset_exit", name: "Uscita al Tramonto", duration: 3.6, loop: false, effect: sunsetExit),
        Preset(id: "pinstripe", name: "Filetto di Ghiaccio", duration: 4.2, loop: true, effect: pinstripe),
        Preset(id: "sill_run", name: "Scia Sottoporta", duration: 4.0, loop: true, effect: sillRun),
        Preset(id: "wheel_halo", name: "Aloni Ruota", duration: 5.0, loop: true, effect: wheelHalo),
        Preset(id: "roof_rays", name: "Raggi sul Tetto", duration: 5.2, loop: true, effect: roofRays),
        Preset(id: "tail_fan", name: "Ventaglio al Retro", duration: 4.8, loop: true, effect: tailFan),
        Preset(id: "bonnet_fan", name: "Ventaglio sul Cofano", duration: 4.6, loop: true, effect: bonnetFan),
        Preset(id: "glass_frame", name: "Cornice dei Vetri", duration: 4.5, loop: true, effect: glassFrame),
        Preset(id: "rapid_trace", name: "Traccia delle Zone", duration: 5.0, loop: true, effect: rapidTrace),
        Preset(id: "flare_arch", name: "Archi Alternati", duration: 5.0, loop: true, effect: flareArch),
        Preset(id: "panels", name: "Pannelli Alternati", duration: 5.4, loop: true, effect: panels),
        Preset(id: "zipper", name: "Cerniera Neon", duration: 4.4, loop: true, effect: zipper),
        Preset(id: "outward", name: "Onda dal Centro", duration: 4.4, loop: true, effect: outward),
        Preset(id: "fold", name: "Onda verso il Centro", duration: 4.4, loop: true, effect: fold),
        Preset(id: "rain_up", name: "Pioggia al Contrario", duration: 5.0, loop: true, effect: rainUp),
        Preset(id: "laser_drift", name: "Taglio Laser", duration: 5.4, loop: true, effect: laserDrift),
        Preset(id: "moire", name: "Interferenze", duration: 5.6, loop: true, effect: moire),
        Preset(id: "slow_magma", name: "Magma Lento", duration: 6.5, loop: true, effect: slowMagma),
        Preset(id: "paper_lantern", name: "Lanterne", duration: 7.0, loop: true, effect: paperLantern),
        Preset(id: "snow_field", name: "Neve Elettrica", duration: 5.0, loop: true, effect: snowField),
        Preset(id: "prismatic", name: "Prisma", duration: 5.4, loop: true, effect: prismatic),
        Preset(id: "city_show", name: "Notte in Città", duration: 12.0, loop: true, effect: montage([city, neonGrid, twinTrails])),
        Preset(id: "ice_show", name: "Tempesta di Cristallo", duration: 12.0, loop: true, effect: montage([blueHour, snowField, scan])),
        Preset(id: "fire_show", name: "Forgia", duration: 12.0, loop: true, effect: montage([slowMagma, ember, flareArch])),
        Preset(id: "orbit_show", name: "Viaggio Orbitale", duration: 12.0, loop: true, effect: montage([orbit, meteor, eclipse])),
        Preset(id: "gold_show", name: "Ora Dorata", duration: 12.0, loop: true, effect: montage([paperLantern, goldenTide, roofRays])),
        Preset(id: "prism_show", name: "Arcade Prisma", duration: 12.0, loop: true, effect: montage([retroArcade, prismatic, moire])),
        Preset(id: "profile_show", name: "Profilo A1", duration: 11.0, loop: true, effect: montage([pinstripe, glassFrame, rapidTrace])),
        Preset(id: "branded_intro", name: "Ingresso A1", duration: 5.4, loop: false, effect: brandedIntro),
        Preset(id: "sendoff", name: "Sipario", duration: 4.0, loop: false, effect: sendoff),
        Preset(id: "landmark", name: "Staffetta delle Zone", duration: 8.0, loop: true, effect: landmark),
    ]

    static func preset(_ id: String) -> Preset? { presets.first { $0.id == id } }

    // MARK: Mappa → campioni e fotogrammi

    struct Point {
        var position: SIMD3<Double>
        var zone: Zone
    }

    /// Campioni per centralina e indirizzo. Un indirizzo senza punti resta spento.
    struct Engine {
        let controllerCount: Int
        let addresses: [[[Sample]]]

        /// `controllers`: numero di indirizzi di ogni centralina nell'ordine della lista;
        /// `points[c][k]`: punti fisici rilevati dell'indirizzo k della centralina c.
        init(addressCounts: [Int], points: [Int: [Int: [Point]]], frontX: Double = 2.0, rearX: Double = -2.0) {
            var seed = 0
            var all: [[[Sample]]] = []
            for (c, count) in addressCounts.enumerated() {
                var list: [[Sample]] = Array(repeating: [], count: max(0, count))
                for (k, pts) in points[c] ?? [:] where k >= 0 && k < count {
                    list[k] = pts.filter { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite }.map { p in
                        Sample(x: min(1, max(0, (p.position.x - rearX) / (frontX - rearX))), h: (p.position.y - 0.3) / 1.2,
                               r: abs(p.position.z), i: seed + k, zone: p.zone)
                    }
                }
                all.append(list)
                seed += max(0, count)
            }
            controllerCount = addressCounts.count
            addresses = all
        }

        /// Posizione normalizzata nell'animazione (0…1).
        static func phase(_ p: Preset, elapsed: Double) -> Double {
            guard elapsed.isFinite, elapsed >= 0 else { return 0 }
            return p.loop ? pmod(elapsed, p.duration) / p.duration : min(elapsed / p.duration, 1)
        }

        /// Un colore per indirizzo: con due punti a Y vince quello col canale più luminoso (come il riferimento).
        func frame(_ p: Preset, elapsed: Double) -> [[RGB]] {
            let u = Engine.phase(p, elapsed: elapsed)
            return addresses.map { list in
                list.map { targets -> RGB in
                    var best: C?
                    var bestPeak = -1.0
                    for t in targets {
                        let c = p.effect(u, t)
                        let peak = max(c.x, c.y, c.z)
                        if peak > bestPeak { bestPeak = peak; best = c }
                    }
                    guard let b = best else { return .black }
                    return RGB(r: UInt8(b.x), g: UInt8(b.y), b: UInt8(b.z))
                }
            }
        }
    }
}
