import Foundation

/// Operazioni dell'editor sulla disposizione reale (punti della mappa), senza UI.
enum MapPainter {
    /// Indice del punto mappato più vicino a (x, y) in pixel della vista, entro `maxDistance`.
    /// `points` usa coordinate normalizzate; `size` è la dimensione della vista.
    static func nearestIndex(points: [MappedPoint], x: Double, y: Double, width: Double, height: Double,
                             maxDistance: Double) -> Int? {
        var best: (Int, Double)?
        for p in points {
            guard let i = p.index else { continue }
            let d = hypot(p.x * width - x, p.y * height - y)
            if d <= maxDistance, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// Colora gli indici i cui punti cadono dentro la maschera (es. testo rasterizzato).
    /// Con il cablaggio a Y un indice può avere due punti: basta che uno sia dentro.
    /// - Parameters:
    ///   - inside: (x, y) normalizzati → true se il punto è nella forma.
    ///   - background: colore per gli indici mappati fuori dalla forma; nil = lasciali com'erano.
    static func apply(points: [MappedPoint], to pixels: [RGB], color: RGB, background: RGB?,
                      inside: (Double, Double) -> Bool) -> [RGB] {
        var out = pixels
        var hit = Set<Int>()
        var mapped = Set<Int>()
        for p in points {
            guard let i = p.index, out.indices.contains(i) else { continue }
            mapped.insert(i)
            if inside(p.x, p.y) { hit.insert(i) }
        }
        for i in mapped {
            if hit.contains(i) {
                out[i] = color
            } else if let background {
                out[i] = background
            }
        }
        return out
    }

    /// Periodo indicativo dell'anteprima per la velocità DIY 1…100 (100 = più veloce).
    /// Il tempo reale dipende dal firmware: l'anteprima serve solo a vedere l'effetto.
    static func previewPeriod(speed: Int) -> Double {
        let s = Double(min(max(speed, 1), 100))
        return 3.0 - (s - 1) / 99 * 2.7
    }

    /// Fattore di luminosità 0…1 dell'anteprima al tempo t.
    static func previewLevel(mode: DIYMode, speed: Int, time t: Double) -> Double {
        let period = previewPeriod(speed: speed)
        let phase = (t / period).truncatingRemainder(dividingBy: 1)
        switch mode {
        case .static: return 1
        case .flash: return phase < 0.5 ? 1 : 0.08
        case .breathe: return 0.15 + 0.85 * (0.5 - 0.5 * cos(phase * 2 * Double.pi))
        }
    }
}
