import Foundation

/// Codifica binaria degli indici LED per la mappatura con fotocamera.
///
/// Ogni LED riceve il codice `indice + 1` (lo 0, "sempre spento", non viene usato).
/// Per ogni bit si mostrano due fotogrammi complementari: il bit si decide confrontando la
/// luminosità del punto nei due fotogrammi, senza soglie assolute (robusto a riflessi e luce
/// ambiente). Due fotogrammi di riferimento (tutto spento, tutto acceso) servono a trovare i punti.
/// Per 200 LED: 8 bit → 2 + 16 = 18 fotogrammi. Non bastano 8 foto: servono i complementari.
struct MappingPlan: Equatable {
    enum Frame: Equatable, Hashable {
        case allOff
        case allOn
        case bit(Int, inverted: Bool)

        var label: String {
            switch self {
            case .allOff: return "Riferimento spento"
            case .allOn: return "Riferimento acceso"
            case let .bit(b, inv): return "Bit \(b + 1)\(inv ? " (complementare)" : "")"
            }
        }
    }

    let ledCount: Int
    let bits: Int
    let frames: [Frame]

    init(ledCount: Int) {
        let n = max(ledCount, 1)
        self.ledCount = n
        var b = 0
        while (1 << b) <= n { b += 1 }   // codici 1...n
        self.bits = max(b, 1)
        var f: [Frame] = [.allOff, .allOn]
        for i in 0..<bits {
            f.append(.bit(i, inverted: false))
            f.append(.bit(i, inverted: true))
        }
        self.frames = f
    }

    static func code(forIndex i: Int) -> Int { i + 1 }

    func isOn(index: Int, in frame: Frame) -> Bool {
        switch frame {
        case .allOff: return false
        case .allOn: return true
        case let .bit(b, inv):
            let set = (MappingPlan.code(forIndex: index) >> b) & 1 == 1
            return inv ? !set : set
        }
    }

    func pattern(for frame: Frame, on: RGB) -> [RGB] {
        (0..<ledCount).map { isOn(index: $0, in: frame) ? on : .black }
    }

    struct Decoded: Equatable {
        /// nil se il codice non è valido o la confidenza è troppo bassa.
        let index: Int?
        let code: Int
        /// Minimo, sui bit, di |a − b| / (a + b): 0 = indeciso, 1 = nettissimo.
        let confidence: Double
    }

    /// `pairs[b] = (luminosità nel fotogramma normale, luminosità nel complementare)`.
    func decode(_ pairs: [(Float, Float)], minConfidence: Double = 0.12) -> Decoded {
        var code = 0
        var conf = 1.0
        for (b, pair) in pairs.enumerated() where b < bits {
            let (a, c) = pair
            if a > c { code |= (1 << b) }
            let sum = Double(a) + Double(c)
            let q = sum > 0 ? abs(Double(a) - Double(c)) / sum : 0
            conf = min(conf, q)
        }
        let index = code - 1
        let valid = pairs.count >= bits && index >= 0 && index < ledCount && conf >= minConfidence
        return Decoded(index: valid ? index : nil, code: code, confidence: conf)
    }
}
