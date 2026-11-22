import Foundation
import simd

/// Raggio di vista (in coordinate del mondo AR, metri).
struct Ray: Equatable, Codable {
    var origin: SIMD3<Double>
    var direction: SIMD3<Double>

    init(origin: SIMD3<Double>, direction: SIMD3<Double>) {
        self.origin = origin
        let l = simd_length(direction)
        self.direction = l > 0 ? direction / l : SIMD3(0, 0, -1)
    }

    func distance(to p: SIMD3<Double>) -> Double {
        let v = p - origin
        return simd_length(v - simd_dot(v, direction) * direction)
    }
}

enum Triangulation {
    /// Punto medio del segmento di minima distanza tra due raggi, distanza tra i raggi e angolo (radianti).
    static func closestPoint(_ a: Ray, _ b: Ray) -> (point: SIMD3<Double>, gap: Double, angle: Double)? {
        let w0 = a.origin - b.origin
        let aa = simd_dot(a.direction, a.direction), bb = simd_dot(b.direction, b.direction)
        let ab = simd_dot(a.direction, b.direction)
        let d = simd_dot(a.direction, w0), e = simd_dot(b.direction, w0)
        let denom = aa * bb - ab * ab
        guard denom > 1e-9 else { return nil }   // raggi paralleli
        let s = (ab * e - bb * d) / denom
        let t = (aa * e - ab * d) / denom
        guard s > 0, t > 0 else { return nil }    // il punto deve stare davanti a entrambe le camere
        let pa = a.origin + s * a.direction, pb = b.origin + t * b.direction
        let angle = acos(min(1, max(-1, ab)))
        return ((pa + pb) / 2, simd_length(pa - pb), angle)
    }

    /// Punto che minimizza la somma dei quadrati delle distanze dai raggi.
    static func leastSquares(_ rays: [Ray]) -> SIMD3<Double>? {
        guard rays.count >= 2 else { return nil }
        var a = simd_double3x3(0)
        var b = SIMD3<Double>(0, 0, 0)
        for r in rays {
            let d = r.direction
            let m = matrix_identity_double3x3 - simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
            a += m
            b += m * r.origin
        }
        guard abs(a.determinant) > 1e-9 else { return nil }
        return a.inverse * b
    }
}

/// Un'osservazione di un pixel logico da una vista: punto 3D (da profondità) o raggio (solo immagine).
struct LEDObservation: Codable, Equatable {
    var key: LEDKey
    var view: Int
    var point: SIMD3<Double>?
    var ray: Ray?
    var weight: Double = 1
}

struct ReconstructedLED: Equatable {
    var key: LEDKey
    var position: SIMD3<Double>
    var views: Int
    var spread: Double
    var confidence: Double
}

/// Ricostruzione delle posizioni 3D da più viste. Per un pixel cablato a Y produce fino a
/// `maxCopies` posizioni fisiche distinte, tutte con la stessa chiave logica.
enum LEDReconstructor {
    struct Options {
        var clusterRadius = 0.08      // m
        var maxRayGap = 0.05          // m, distanza massima tra due raggi per accettarne l'incrocio
        var minRayAngle = 3.0 * Double.pi / 180
    }

    private struct Candidate { var p: SIMD3<Double>; var views: Set<Int>; var weight: Double }

    static func reconstruct(_ observations: [LEDObservation], maxCopies: Int, options: Options = Options()) -> [ReconstructedLED] {
        var out: [ReconstructedLED] = []
        for (key, obs) in Dictionary(grouping: observations, by: { $0.key }) {
            out += reconstructKey(key, obs, maxCopies: max(maxCopies, 1), options: options)
        }
        return out.sorted { $0.key < $1.key }
    }

    private static func reconstructKey(_ key: LEDKey, _ obs: [LEDObservation], maxCopies: Int, options: Options) -> [ReconstructedLED] {
        var cands: [Candidate] = []
        for o in obs { if let p = o.point { cands.append(Candidate(p: p, views: [o.view], weight: o.weight)) } }
        let rays = obs.compactMap { o -> (Ray, Int)? in o.ray.map { ($0, o.view) } }
        if rays.count >= 2 {
            for i in 0..<rays.count {
                for j in (i + 1)..<rays.count where rays[i].1 != rays[j].1 {
                    if let c = Triangulation.closestPoint(rays[i].0, rays[j].0),
                       c.gap <= options.maxRayGap, c.angle >= options.minRayAngle {
                        cands.append(Candidate(p: c.point, views: [rays[i].1, rays[j].1], weight: 1))
                    }
                }
            }
        }
        var remaining = cands
        var result: [ReconstructedLED] = []
        while !remaining.isEmpty && result.count < maxCopies {
            // Candidato con più sostegno nel raggio di cluster.
            var bestIndex = 0, bestScore = -1.0
            for (i, c) in remaining.enumerated() {
                let score = remaining.filter { simd_distance($0.p, c.p) <= options.clusterRadius }.reduce(0) { $0 + $1.weight }
                if score > bestScore { bestScore = score; bestIndex = i }
            }
            let center = remaining[bestIndex].p
            let members = remaining.filter { simd_distance($0.p, center) <= options.clusterRadius }
            remaining.removeAll { simd_distance($0.p, center) <= options.clusterRadius }
            let views = members.reduce(into: Set<Int>()) { $0.formUnion($1.views) }
            let wsum = members.reduce(0) { $0 + $1.weight }
            var pos = members.reduce(SIMD3<Double>(0, 0, 0)) { $0 + $1.p * $1.weight } / max(wsum, 1e-9)
            // Rifinitura ai minimi quadrati con i raggi che passano vicino al cluster.
            let near = rays.map { $0.0 }.filter { $0.distance(to: pos) <= options.clusterRadius }
            if near.count >= 2, let refined = Triangulation.leastSquares(near), simd_distance(refined, pos) <= options.clusterRadius {
                pos = refined
            }
            let spread = members.map { simd_distance($0.p, pos) }.max() ?? 0
            let viewScore = min(1, 0.35 + 0.2 * Double(views.count))
            let confidence = viewScore * exp(-spread / options.clusterRadius)
            // Un solo raggio non basta: serve almeno un punto di profondità o due viste.
            let hasDepth = members.contains { $0.views.count == 1 }
            if views.count >= 2 || hasDepth {
                result.append(ReconstructedLED(key: key, position: pos, views: views.count, spread: spread, confidence: confidence))
            }
        }
        return result
    }
}

/// Allineamento della nuvola di LED al sistema dell'auto: x avanti, y in alto, z a destra (sinistra = −z, terna destrorsa come glTF/SceneKit), metri,
/// origine al centro dell'auto a terra.
struct CarAlignment: Codable, Equatable {
    var yaw: Double = 0                     // rotazione attorno a y
    var offset = SIMD3<Double>(0, 0, 0)     // punto del mondo AR che diventa l'origine
    var scale: Double = 1

    func toCar(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let q = p - offset
        let c = cos(-yaw), s = sin(-yaw)
        return SIMD3(c * q.x - s * q.z, q.y, s * q.x + c * q.z) * scale
    }
}

enum AutoAlign {
    /// Asse principale dei LED in pianta → asse x dell'auto; base dei LED a y = groundClearance.
    static func fit(_ points: [SIMD3<Double>], groundClearance: Double = 0.25) -> CarAlignment {
        guard points.count >= 3 else { return CarAlignment() }
        let n = Double(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / n
        let cz = points.reduce(0) { $0 + $1.z } / n
        var sxx = 0.0, szz = 0.0, sxz = 0.0
        for p in points {
            let dx = p.x - cx, dz = p.z - cz
            sxx += dx * dx; szz += dz * dz; sxz += dx * dz
        }
        let theta = 0.5 * atan2(2 * sxz, sxx - szz)   // direzione di massima varianza
        let minY = points.map { $0.y }.min() ?? 0
        return CarAlignment(yaw: theta, offset: SIMD3(cx, minY - groundClearance, cz), scale: 1)
    }
}

/// Zone della carrozzeria nel sistema dell'auto.
enum CarZone: String, Codable, CaseIterable, Identifiable {
    case all, front, rear, left, right, roof
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Tutta l'auto"
        case .front: return "Frontale"
        case .rear: return "Posteriore"
        case .left: return "Lato sinistro"
        case .right: return "Lato destro"
        case .roof: return "Tetto"
        }
    }
}

/// Dimensioni Audi A1 Sportback 2020 (dati di catalogo, arrotondati).
enum CarDimensions {
    static let length = 4.03
    static let width = 1.74
    static let height = 1.41
}

enum ZoneClassifier {
    static func zone(of p: SIMD3<Double>) -> CarZone {
        let halfL = CarDimensions.length / 2
        if p.y > CarDimensions.height * 0.78 { return .roof }
        if p.x > halfL * 0.62 { return .front }
        if p.x < -halfL * 0.62 { return .rear }
        return p.z <= 0 ? .left : .right   // z negativo = sinistra (come glTF)
    }

    static func contains(_ zone: CarZone, _ p: SIMD3<Double>) -> Bool {
        zone == .all || self.zone(of: p) == zone
    }
}
