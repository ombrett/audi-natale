import Foundation

/// Sistema di assi di un file esterno, espresso come direzioni "+X", "-Z", …
/// L'app usa x = avanti, y = alto, z = destra (sinistra = −z): la stessa terna destrorsa di glTF/SceneKit.
struct AxisFrame: Equatable {
    var front: SIMD3<Double>
    var up: SIMD3<Double>
    var left: SIMD3<Double>

    static let app = AxisFrame(front: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), left: SIMD3(0, 0, -1))

    static func axis(_ s: String?) -> SIMD3<Double>? {
        guard var t = s?.trimmingCharacters(in: .whitespaces).uppercased(), !t.isEmpty else { return nil }
        var sign = 1.0
        if t.hasPrefix("-") { sign = -1; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        switch t {
        case "X": return SIMD3(sign, 0, 0)
        case "Y": return SIMD3(0, sign, 0)
        case "Z": return SIMD3(0, 0, sign)
        default: return nil
        }
    }

    /// Le tre direzioni devono essere assi distinti.
    var isValid: Bool {
        let a = [front, up, left].map { v -> Int in v.x != 0 ? 0 : (v.y != 0 ? 1 : 2) }
        return Set(a).count == 3
    }

    /// Converte un punto del file nel sistema dell'app.
    func toApp(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let x = (p * front).sum(), y = (p * up).sum(), l = (p * left).sum()
        return SIMD3(x, y, -l)
    }

    /// Vero se la conversione è una riflessione (serve invertire l'ordine dei triangoli).
    var isMirror: Bool {
        // Righe della matrice file→app: front, up, −left.
        let r0 = front, r1 = up, r2 = -left
        let det = r0.x * (r1.y * r2.z - r1.z * r2.y) - r0.y * (r1.x * r2.z - r1.z * r2.x) + r0.z * (r1.x * r2.y - r1.y * r2.x)
        return det < 0
    }
}

/// File di layout LED esportato dal progetto (es. Blender): posizioni previste di ogni LED fisico,
/// per centralina e indirizzo, con le copie a Y ("targets").
struct LEDLayoutFile: Codable {
    struct CoordinateSystem: Codable {
        var format: String?
        var unit: String?
        var up: String?
        var vehicle_front: String?
        var vehicle_left: String?
    }
    struct Target: Codable {
        var branch: String?
        var node: String?
        var position: [Double]
    }
    struct Address: Codable {
        var index: Int
        var zone: String?
        var targets: [Target]
    }
    struct Controller: Codable {
        var id: String
        var address_count: Int?
        var physical_led_count: Int?
        var branch_count: Int?
        var addresses: [Address]
    }
    var schema_version: Int?
    var coordinate_system: CoordinateSystem?
    var led_index_base: Int?
    var physical_led_count: Int?
    var logical_led_count: Int?
    var topology: String?
    var controllers: [Controller]
}

enum LEDLayoutImport {
    struct Point: Equatable {
        var controller: Int        // posizione della centralina nel file (0 = prima)
        var pixel: Int             // indirizzo 0-based
        var position: SIMD3<Double>   // sistema dell'app, metri
        var zone: String?
        var branch: String?
    }

    struct Controller: Equatable {
        var name: String
        var addressCount: Int
        var branches: Int
    }

    struct Result: Equatable {
        var controllers: [Controller]
        var points: [Point]
        var frame: AxisFrame
        var warnings: [String]
        var physicalCount: Int { points.count }
        var logicalCount: Int { Set(points.map { "\($0.controller)#\($0.pixel)" }).count }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case unreadable(String)
        case noControllers
        case tooManyControllers(Int)
        case tooManyAddresses(String, Int)
        case badIndex(String, Int)
        case duplicate(String, Int)
        case badPosition(String, Int)
        case badAxes

        var errorDescription: String? {
            switch self {
            case .unreadable(let m): return "File di layout non leggibile: \(m)"
            case .noControllers: return "Il file non contiene centraline."
            case .tooManyControllers(let n): return "Il file descrive \(n) centraline: il massimo gestito è 8."
            case .tooManyAddresses(let c, let n): return "Centralina \(c): \(n) indirizzi, oltre il limite sicuro di \(IdealProtocol.maxSafeLEDs)."
            case .badIndex(let c, let i): return "Centralina \(c): indirizzo \(i) fuori intervallo."
            case .duplicate(let c, let i): return "Centralina \(c): indirizzo \(i) ripetuto."
            case .badPosition(let c, let i): return "Centralina \(c), indirizzo \(i): posizione non valida."
            case .badAxes: return "Sistema di assi del file non valido."
            }
        }
    }

    static let maxControllers = 8
    /// Oltre questa distanza dall'origine (m) un punto non può appartenere a un'auto.
    static let maxDistance = 10.0

    static func parse(_ data: Data) throws -> Result {
        let file: LEDLayoutFile
        do { file = try JSONDecoder().decode(LEDLayoutFile.self, from: data) }
        catch { throw Failure.unreadable(String(describing: error).prefix(160).description) }
        return try convert(file)
    }

    static func convert(_ file: LEDLayoutFile) throws -> Result {
        var warnings: [String] = []
        guard !file.controllers.isEmpty else { throw Failure.noControllers }
        guard file.controllers.count <= maxControllers else { throw Failure.tooManyControllers(file.controllers.count) }

        let cs = file.coordinate_system
        var frame = AxisFrame(front: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), left: SIMD3(0, 0, -1))   // convenzione glTF
        if let cs {
            if let u = cs.up { guard let v = AxisFrame.axis(u) else { throw Failure.badAxes }; frame.up = v }
            if let f = cs.vehicle_front { guard let v = AxisFrame.axis(f) else { throw Failure.badAxes }; frame.front = v }
            if let l = cs.vehicle_left { guard let v = AxisFrame.axis(l) else { throw Failure.badAxes }; frame.left = v }
            if let unit = cs.unit?.lowercased(), !["meter", "metre", "m", "meters", "metri"].contains(unit) {
                warnings.append("Unità \"\(unit)\" non in metri: le posizioni sono state lette come metri.")
            }
        } else {
            warnings.append("Sistema di assi assente: assunto glTF (avanti +X, alto +Y, sinistra −Z).")
        }
        guard frame.isValid else { throw Failure.badAxes }

        let base = file.led_index_base ?? 0
        var controllers: [Controller] = []
        var points: [Point] = []
        for (ci, c) in file.controllers.enumerated() {
            let maxIndex = c.addresses.map { $0.index - base }.max() ?? -1
            let count = max(c.address_count ?? 0, maxIndex + 1)
            guard count <= IdealProtocol.maxSafeLEDs else { throw Failure.tooManyAddresses(c.id, count) }
            var seen = Set<Int>()
            var branches = c.branch_count ?? 0
            for a in c.addresses {
                let idx = a.index - base
                guard idx >= 0, idx < count else { throw Failure.badIndex(c.id, a.index) }
                guard seen.insert(idx).inserted else { throw Failure.duplicate(c.id, a.index) }
                branches = max(branches, a.targets.count)
                for t in a.targets {
                    guard t.position.count == 3, t.position.allSatisfy({ $0.isFinite }) else { throw Failure.badPosition(c.id, a.index) }
                    let p = SIMD3(t.position[0], t.position[1], t.position[2])
                    guard (p * p).sum().squareRoot() <= maxDistance else { throw Failure.badPosition(c.id, a.index) }
                    points.append(Point(controller: ci, pixel: idx, position: frame.toApp(p), zone: a.zone, branch: t.branch))
                }
            }
            if seen.count < count { warnings.append("Centralina \(c.id): \(count - seen.count) indirizzi senza posizione.") }
            if let declared = c.physical_led_count, declared != c.addresses.reduce(0, { $0 + $1.targets.count }) {
                warnings.append("Centralina \(c.id): LED fisici dichiarati \(declared), trovati \(c.addresses.reduce(0) { $0 + $1.targets.count }).")
            }
            controllers.append(Controller(name: c.id, addressCount: count, branches: max(branches, 1)))
        }
        if let declared = file.physical_led_count, declared != points.count {
            warnings.append("LED fisici dichiarati \(declared), trovati \(points.count).")
        }
        return Result(controllers: controllers, points: points, frame: frame, warnings: warnings)
    }
}
