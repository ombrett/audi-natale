import Foundation

/// Immagine in scala di grigi (luminanza 0…255) usata per l'analisi; nessuna dipendenza da UIKit.
struct GrayImage: Equatable {
    let width: Int
    let height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, pixels: [Float](repeating: fill, count: width * height))
    }

    subscript(x: Int, y: Int) -> Float {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Media di più immagini della stessa dimensione (riduce il rumore del sensore).
    static func average(_ images: [GrayImage]) -> GrayImage? {
        guard let first = images.first, images.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { return nil }
        var acc = [Float](repeating: 0, count: first.pixels.count)
        for img in images {
            for i in acc.indices { acc[i] += img.pixels[i] }
        }
        let k = Float(images.count)
        return GrayImage(width: first.width, height: first.height, pixels: acc.map { $0 / k })
    }

    /// a − b, limitato a ≥ 0.
    static func difference(_ a: GrayImage, _ b: GrayImage) -> GrayImage? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var out = a.pixels
        for i in out.indices { out[i] = max(0, a.pixels[i] - b.pixels[i]) }
        return GrayImage(width: a.width, height: a.height, pixels: out)
    }
}

struct Blob: Equatable {
    /// Centroide pesato sulla luminosità, in pixel.
    var x: Double
    var y: Double
    var area: Int
    var peak: Float
}

enum BlobDetector {
    struct Options {
        /// Soglia relativa al picco dell'immagine differenza.
        var relativeThreshold: Float = 0.25
        /// Soglia minima assoluta sulla differenza (0…255).
        var minimumThreshold: Float = 12
        var minArea = 2
        var maxArea = 5000
    }

    /// Trova i punti luminosi in un'immagine differenza (acceso − spento).
    static func detect(_ img: GrayImage, options: Options = Options()) -> [Blob] {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return [] }
        var peak: Float = 0
        var sum: Double = 0
        var sumSq: Double = 0
        for v in img.pixels {
            peak = max(peak, v)
            sum += Double(v)
            sumSq += Double(v) * Double(v)
        }
        let n = Double(img.pixels.count)
        let mean = sum / n
        let std = max(0, sumSq / n - mean * mean).squareRoot()
        let threshold = max(options.minimumThreshold, peak * options.relativeThreshold, Float(mean + 4 * std))
        // Serve un contrasto reale rispetto alla media (un cambio uniforme di luce non è un LED).
        guard peak >= threshold, Double(peak) - mean >= Double(options.minimumThreshold) else { return [] }

        var visited = [Bool](repeating: false, count: w * h)
        var blobs: [Blob] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where !visited[start] && img.pixels[start] >= threshold {
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var area = 0
            var wsum: Double = 0, xs: Double = 0, ys: Double = 0
            var bpeak: Float = 0
            while let p = stack.popLast() {
                let v = img.pixels[p]
                let px = p % w, py = p / w
                area += 1
                let weight = Double(v - threshold) + 1
                wsum += weight
                xs += Double(px) * weight
                ys += Double(py) * weight
                bpeak = max(bpeak, v)
                for dy in -1...1 {
                    let ny = py + dy
                    if ny < 0 || ny >= h { continue }
                    for dx in -1...1 {
                        let nx = px + dx
                        if nx < 0 || nx >= w || (dx == 0 && dy == 0) { continue }
                        let q = ny * w + nx
                        if !visited[q] && img.pixels[q] >= threshold {
                            visited[q] = true
                            stack.append(q)
                        }
                    }
                }
            }
            if area >= options.minArea && area <= options.maxArea {
                blobs.append(Blob(x: xs / wsum, y: ys / wsum, area: area, peak: bpeak))
            }
        }
        return blobs
    }

    /// Luminosità media in un quadrato di lato 2r+1 attorno al punto.
    static func sample(_ img: GrayImage, x: Double, y: Double, radius: Int) -> Float {
        let cx = Int(x.rounded()), cy = Int(y.rounded())
        var total: Float = 0
        var count = 0
        for yy in max(0, cy - radius)...min(img.height - 1, cy + radius) {
            for xx in max(0, cx - radius)...min(img.width - 1, cx + radius) {
                total += img[xx, yy]
                count += 1
            }
        }
        return count > 0 ? total / Float(count) : 0
    }

    /// Raggio di campionamento adatto all'area del punto.
    static func radius(forArea area: Int) -> Int {
        max(1, min(6, Int((Double(area) / Double.pi).squareRoot().rounded())))
    }
}

/// Punto mappato: posizione normalizzata (0…1) nell'inquadratura e indice LED.
struct MappedPoint: Codable, Equatable, Identifiable {
    var id = UUID()
    var index: Int?
    var x: Double
    var y: Double
    var confidence: Double
    var area: Int
    var manual = false
}

enum MappingDecoder {
    struct DecodeOptions {
        /// Soglia della maschera "acceso − spento", relativa al picco (bassa: i LED lontani sono più deboli).
        var maskRelative: Float = 0.12
        var maskMinimum: Float = 12
        /// Per ogni bit, |normale − complementare| deve valere almeno questa frazione di (acceso − spento).
        /// I pixel dove due LED si sovrappongono hanno bit ambigui e vengono scartati.
        var bitContrast: Float = 0.3
        var minArea = 2
        /// Copie attese di ogni indice nell'inquadratura (2 con il cablaggio a Y).
        var expectedCopies = 2
        /// Una copia più debole di questa frazione della più forte è considerata un riflesso.
        var reflectionRatio = 0.2
    }

    /// Decodifica per pixel: ogni pixel acceso riceve il suo codice, poi i pixel adiacenti con lo
    /// stesso codice formano un punto. LED fusi nell'immagine si separano perché hanno codici diversi.
    /// I punti luminosi senza codice valido restano come punti "senza indice" (correggibili a mano).
    static func decode(plan: MappingPlan, frames: [MappingPlan.Frame: GrayImage],
                       options: DecodeOptions = DecodeOptions()) -> [MappedPoint] {
        guard let off = frames[.allOff], let on = frames[.allOn],
              let diff = GrayImage.difference(on, off) else { return [] }
        var bitFrames: [(GrayImage, GrayImage)] = []
        for b in 0..<plan.bits {
            guard let a = frames[.bit(b, inverted: false)], let c = frames[.bit(b, inverted: true)],
                  a.width == diff.width, c.width == diff.width else { return [] }
            bitFrames.append((a, c))
        }
        let w = diff.width, h = diff.height, count = w * h
        var peak: Float = 0
        var sum: Double = 0
        var sumSq: Double = 0
        for v in diff.pixels { peak = max(peak, v); sum += Double(v); sumSq += Double(v) * Double(v) }
        let mean = sum / Double(count)
        let std = max(0, sumSq / Double(count) - mean * mean).squareRoot()
        let threshold = max(options.maskMinimum, peak * options.maskRelative, Float(mean + 3 * std))
        guard peak >= threshold, Double(peak) - mean >= Double(options.maskMinimum) else { return [] }

        // 1. Codice per pixel (-1 = spento o ambiguo)
        var codeMap = [Int](repeating: -1, count: count)
        for p in 0..<count {
            let d = diff.pixels[p]
            if d < threshold { continue }
            var code = 0
            var ok = true
            for (bit, pair) in bitFrames.enumerated() {
                let a = pair.0.pixels[p], c = pair.1.pixels[p]
                if abs(a - c) < options.bitContrast * d { ok = false; break }
                if a > c { code |= (1 << bit) }
            }
            let index = code - 1
            if ok && index >= 0 && index < plan.ledCount { codeMap[p] = index }
        }

        // 2. Componenti connesse con lo stesso codice
        struct Comp { var index: Int; var x: Double; var y: Double; var area: Int; var weight: Double }
        var comps: [Comp] = []
        var visited = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        for start in 0..<count where codeMap[start] >= 0 && !visited[start] {
            let idx = codeMap[start]
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var area = 0
            var wsum = 0.0, xs = 0.0, ys = 0.0
            while let p = stack.popLast() {
                let px = p % w, py = p / w
                let wt = Double(diff.pixels[p])
                area += 1; wsum += wt; xs += Double(px) * wt; ys += Double(py) * wt
                for dy in -1...1 {
                    let ny = py + dy
                    if ny < 0 || ny >= h { continue }
                    for dx in -1...1 {
                        let nx = px + dx
                        if nx < 0 || nx >= w { continue }
                        let q = ny * w + nx
                        if !visited[q] && codeMap[q] == idx { visited[q] = true; stack.append(q) }
                    }
                }
            }
            if area >= options.minArea && wsum > 0 {
                comps.append(Comp(index: idx, x: xs / wsum, y: ys / wsum, area: area, weight: wsum))
            }
        }

        // 3. Per indice: tieni le copie più forti, scarta i riflessi deboli
        var kept: [Comp] = []
        for (_, group) in Dictionary(grouping: comps, by: { $0.index }) {
            let sorted = group.sorted { $0.weight > $1.weight }
            let strongest = sorted[0].weight
            for c in sorted.prefix(options.expectedCopies) where c.weight >= strongest * options.reflectionRatio {
                kept.append(c)
            }
        }

        let sx = Double(max(w - 1, 1)), sy = Double(max(h - 1, 1))
        var points = kept.map {
            MappedPoint(index: $0.index, x: $0.x / sx, y: $0.y / sy, confidence: 1, area: $0.area)
        }

        // 4. Punti luminosi senza alcun codice valido vicino: "senza indice"
        var blobOptions = BlobDetector.Options()
        blobOptions.relativeThreshold = max(options.maskRelative * 2, 0.25)
        for blob in BlobDetector.detect(diff, options: blobOptions) {
            let radius = max(3.0, Double(blob.area).squareRoot())
            let covered = kept.contains { hypot($0.x - blob.x, $0.y - blob.y) <= radius }
            if !covered {
                points.append(MappedPoint(index: nil, x: blob.x / sx, y: blob.y / sy, confidence: 0, area: blob.area))
            }
        }
        return points.sorted { ($0.index ?? Int.max, $0.x) < ($1.index ?? Int.max, $1.x) }
    }

    struct Summary: Equatable {
        var points: Int
        var decoded: Int
        var uniqueIndices: Int
        var duplicatedIndices: Int   // indici visti più volte (normale con cablaggio a Y)
        var conflicts: Int           // indici visti più di `expectedCopies` volte
        var missing: [Int]
    }

    static func summarize(_ points: [MappedPoint], ledCount: Int, expectedCopies: Int = 2) -> Summary {
        var counts: [Int: Int] = [:]
        for p in points { if let i = p.index { counts[i, default: 0] += 1 } }
        let missing = (0..<ledCount).filter { counts[$0] == nil }
        return Summary(points: points.count,
                       decoded: points.filter { $0.index != nil }.count,
                       uniqueIndices: counts.count,
                       duplicatedIndices: counts.values.filter { $0 > 1 }.count,
                       conflicts: counts.values.filter { $0 > expectedCopies }.count,
                       missing: missing)
    }
}
