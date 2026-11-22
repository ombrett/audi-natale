import Foundation
import simd

/// Forma parametrica di una hatchback 5 porte con le misure dell'Audi A1 Sportback 2020
/// (sistema dell'auto: x avanti, y in alto, z a sinistra, metri, origine al centro a terra).
/// È una ricostruzione approssimata del profilo, non il modello ufficiale: serve sia a disegnare
/// il modello 3D provvisorio sia a posare i LED della mappa dimostrativa sulla carrozzeria.
enum CarShape {
    static let halfLength = CarDimensions.length / 2
    static let wheelBase = 2.56
    static let wheelRadius = 0.31
    static let archRadius = 0.37
    static let frontAxle = 1.25
    static let rearAxle = -1.31

    // Profilo superiore (cofano → parabrezza → tetto → lunotto), dal posteriore all'anteriore.
    private static let topProfile: [(Double, Double)] = [
        (-2.015, 0.93), (-1.985, 1.08), (-1.93, 1.24), (-1.86, 1.335), (-1.75, 1.375), (-0.9, 1.415),
        (-0.2, 1.415), (0.15, 1.395), (0.28, 1.36), (0.95, 0.99), (1.2, 0.955), (1.75, 0.865),
        (1.95, 0.77), (2.015, 0.62),
    ]
    // Linea di cintura (bordo inferiore dei finestrini).
    private static let beltProfile: [(Double, Double)] = [
        (-2.015, 0.92), (-1.93, 0.99), (-1.7, 1.01), (-0.6, 0.985), (0.6, 0.955), (0.95, 0.94),
        (1.6, 0.86), (2.015, 0.60),
    ]
    // Fondo della scocca (senza i passaruota).
    private static let bottomProfile: [(Double, Double)] = [
        (-2.015, 0.42), (-1.97, 0.34), (-1.88, 0.30), (1.80, 0.27), (1.97, 0.33), (2.015, 0.40),
    ]

    /// Sezioni lungo la lunghezza, più fitte alle estremità e ai passaruota.
    static var stations: [Double] {
        var s: [Double] = []
        let n = 90
        for i in 0...n {
            let t = Double(i) / Double(n)
            s.append(-halfLength + (1 - cos(t * .pi)) / 2 * 2 * halfLength)
        }
        return s
    }

    static func topY(_ x: Double) -> Double { interp(topProfile, x) }

    static func beltY(_ x: Double) -> Double { min(interp(beltProfile, x), topY(x) - 0.015) }

    /// Fondo con i passaruota: sopra le ruote la scocca sale ad arco.
    static func bottomY(_ x: Double) -> Double {
        var y = interp(bottomProfile, x)
        for axle in [frontAxle, rearAxle] {
            let d = abs(x - axle)
            if d < archRadius {
                y = max(y, wheelRadius + (archRadius * archRadius - d * d).squareRoot())
            }
        }
        return y
    }

    /// Abitacolo (finestrini) dove la cintura è nettamente sotto il tetto.
    static func isCabin(_ x: Double) -> Bool { topY(x) - beltY(x) > 0.14 }

    /// Riduzione della larghezza alle estremità (muso e coda arrotondati in pianta).
    static func taper(_ x: Double) -> Double {
        let front = smooth(1.70, 2.015, x), rear = smooth(-1.85, -2.015, x)
        return 1 - 0.16 * front - 0.10 * rear
    }

    /// Vetri: laterali tra montante A e montante posteriore pieno, parabrezza, lunotto.
    static let sideGlass: ClosedRange<Double> = -1.47...0.86
    static let windshield: ClosedRange<Double> = 0.30...0.93
    static let rearWindow: ClosedRange<Double> = -1.97...(-1.72)

    static let sillHalfWidth = 0.84
    static let beltHalfWidth = 0.87
    static let roofHalfWidth = 0.63
    static let hoodHalfWidth = 0.80

    /// Semilarghezza della carrozzeria all'altezza y nella sezione x.
    static func halfWidth(x: Double, y: Double) -> Double {
        let b = bottomY(x), bl = beltY(x), t = topY(x)
        let k = taper(x)
        if y <= bl {
            let u = max(0, min(1, (y - b) / max(bl - b, 0.01)))
            return k * (sillHalfWidth + (beltHalfWidth - sillHalfWidth) * sin(u * .pi / 2))
        }
        let topW = isCabin(x) ? roofHalfWidth : hoodHalfWidth
        let u = max(0, min(1, (y - bl) / max(t - bl, 0.01)))
        return k * (beltHalfWidth + (topW - beltHalfWidth) * u * u)
    }

    /// Altezza della superficie superiore (tetto/cofano) a distanza z dal centro: leggera bombatura.
    static func topSurfaceY(x: Double, z: Double) -> Double {
        let t = topY(x)
        let w = (isCabin(x) ? roofHalfWidth : hoodHalfWidth) * taper(x)
        let u = min(1, abs(z) / max(w, 0.01))
        return t - 0.05 * u * u
    }

    /// Profilo di una sezione: punti (z, y) dal fondo al centro del tetto sul lato sinistro. `panel` è il tipo
    /// del segmento che arriva a quel punto dal precedente (per i materiali).
    enum Panel { case underside, side, window, top }

    static func halfSection(_ x: Double) -> [(z: Double, y: Double, panel: Panel)] {
        let b = bottomY(x), bl = beltY(x), t = topY(x)
        let cabin = isCabin(x)
        var pts: [(Double, Double, Panel)] = []
        pts.append((0, b, .underside))
        pts.append((halfWidth(x: x, y: b) * 0.90, b, .underside))
        for i in 1...4 {
            let y = b + (bl - b) * Double(i) / 4
            pts.append((halfWidth(x: x, y: y), y, .side))
        }
        let topW = (cabin ? roofHalfWidth : hoodHalfWidth) * taper(x)
        for i in 1...3 {
            let y = bl + (t - 0.035 - bl) * Double(i) / 3
            pts.append((halfWidth(x: x, y: y), y, (cabin && sideGlass.contains(x)) ? .window : .top))
        }
        let g: Panel = (windshield.contains(x) || rearWindow.contains(x)) ? .window : .top
        pts.append((topW * 0.80, t - 0.012, .top))
        pts.append((topW * 0.40, t, g))
        pts.append((0, t + 0.004, g))
        return pts.map { (z: $0.0, y: $0.1, panel: $0.2) }
    }

    // MARK: Interpolazione

    /// Interpolazione cubica monotona (Fritsch–Carlson): curva morbida senza gobbe tra i punti.
    static func interp(_ t: [(Double, Double)], _ x: Double) -> Double {
        guard let first = t.first, let last = t.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        let n = t.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (t[i + 1].1 - t[i].1) / (t[i + 1].0 - t[i].0) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let h = a * a + b * b
            if h > 9 { let k = 3 / h.squareRoot(); m[i] = k * a * d[i]; m[i + 1] = k * b * d[i] }
        }
        for i in 1..<n where x <= t[i].0 {
            let (x0, y0) = t[i - 1], (x1, y1) = t[i]
            let h = x1 - x0, u = (x - x0) / h
            let u2 = u * u, u3 = u2 * u
            return (2 * u3 - 3 * u2 + 1) * y0 + (u3 - 2 * u2 + u) * h * m[i - 1] + (-2 * u3 + 3 * u2) * y1 + (u3 - u2) * h * m[i]
        }
        return last.1
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
