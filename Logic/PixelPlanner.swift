import Foundation

/// Operazione verificata sul dispositivo: DOOD pixel singolo o DOOD riempi-tutto.
enum PixelOp: Equatable {
    case fill(RGB)
    case pixel(Int, RGB)
}

/// Calcola il minimo di comandi DOOD per passare dallo stato noto della tela al disegno voluto.
/// Usa solo comandi verificati su ISP-B0717F: niente DOOT finché il formato con MTU 23 non è catturato.
enum PixelPlanner {
    /// - Parameters:
    ///   - current: stato noto del controller; nil se sconosciuto (allora si riempie sempre).
    ///   - target: colore per ogni indice 0..<n.
    static func plan(current: [RGB]?, target: [RGB]) -> [PixelOp] {
        guard !target.isEmpty else { return [] }
        let background = mostFrequent(target)
        let overBackground = target.indices.filter { target[$0] != background }
        let fillPlan: [PixelOp] = [.fill(background)] + overBackground.map { .pixel($0, target[$0]) }

        guard let current, current.count == target.count else { return fillPlan }
        let changed = target.indices.filter { current[$0] != target[$0] }
        if changed.isEmpty { return [] }
        let directPlan: [PixelOp] = changed.map { .pixel($0, target[$0]) }
        return directPlan.count <= fillPlan.count ? directPlan : fillPlan
    }

    /// Applica un'operazione confermata allo stato noto.
    static func apply(_ op: PixelOp, to state: inout [RGB]) {
        switch op {
        case .fill(let c):
            for i in state.indices { state[i] = c }
        case .pixel(let i, let c):
            if state.indices.contains(i) { state[i] = c }
        }
    }

    static func mostFrequent(_ colors: [RGB]) -> RGB {
        var counts: [RGB: Int] = [:]
        var best = colors[0]
        var bestCount = 0
        for c in colors {
            let n = (counts[c] ?? 0) + 1
            counts[c] = n
            if n > bestCount { best = c; bestCount = n }
        }
        return best
    }
}
