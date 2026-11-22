import UIKit

/// Rasterizza un testo in una maschera alfa grande quanto l'inquadratura della mappa.
struct TextMask {
    let width: Int
    let height: Int
    private let alpha: [UInt8]

    /// - Parameters:
    ///   - heightFraction: altezza del testo rispetto al lato su cui scorre.
    ///   - rotated: ruota di 90° (utile se la foto della mappa è stata fatta col telefono in orizzontale).
    init?(text: String, width: Int, height: Int, heightFraction: Double, rotated: Bool) {
        guard width > 0, height > 0, !text.isEmpty else { return nil }
        self.width = width
        self.height = height
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let longSide = rotated ? CGFloat(height) : CGFloat(width)
            let shortSide = rotated ? CGFloat(width) : CGFloat(height)
            var fontSize = shortSide * CGFloat(heightFraction)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: UIColor.white,
            ]
            var textSize = (text as NSString).size(withAttributes: attrs)
            if textSize.width > longSide * 0.95 {   // riduci per farlo stare nell'inquadratura
                fontSize *= longSide * 0.95 / textSize.width
                attrs[.font] = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
                textSize = (text as NSString).size(withAttributes: attrs)
            }
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            if rotated { cg.rotate(by: -.pi / 2) }
            (text as NSString).draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2), withAttributes: attrs)
        }
        guard let cgImage = image.cgImage else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Testo bianco su trasparente → luminanza su nero.
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        alpha = buffer
    }

    /// True se c'è testo entro `radius` pixel dal punto normalizzato (x, y).
    func contains(x: Double, y: Double, radius: Int = 2) -> Bool {
        let cx = Int(x * Double(width - 1)), cy = Int(y * Double(height - 1))
        for yy in max(0, cy - radius)...min(height - 1, cy + radius) {
            for xx in max(0, cx - radius)...min(width - 1, cx + radius) where alpha[yy * width + xx] > 128 {
                return true
            }
        }
        return false
    }
}
