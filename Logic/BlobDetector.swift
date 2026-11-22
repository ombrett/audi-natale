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
    /// Decodifica i fotogrammi catturati. `frames` deve contenere tutti i fotogrammi del piano.
    static func decode(plan: MappingPlan, frames: [MappingPlan.Frame: GrayImage],
                       options: BlobDetector.Options = BlobDetector.Options()) -> [MappedPoint] {
        guard let off = frames[.allOff], let on = frames[.allOn],
              let diff = GrayImage.difference(on, off) else { return [] }
        let blobs = BlobDetector.detect(diff, options: options)
        return blobs.map { blob in
            let r = BlobDetector.radius(forArea: blob.area)
            var pairs: [(Float, Float)] = []
            for b in 0..<plan.bits {
                guard let a = frames[.bit(b, inverted: false)], let c = frames[.bit(b, inverted: true)] else { break }
                pairs.append((BlobDetector.sample(a, x: blob.x, y: blob.y, radius: r),
                              BlobDetector.sample(c, x: blob.x, y: blob.y, radius: r)))
            }
            let d = plan.decode(pairs)
            return MappedPoint(index: d.index,
                               x: blob.x / Double(max(diff.width - 1, 1)),
                               y: blob.y / Double(max(diff.height - 1, 1)),
                               confidence: d.confidence, area: blob.area)
        }
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
