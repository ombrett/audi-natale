import Foundation
import simd

/// Effetti aggiuntivi del motore. Tutti dipendono solo da (parametri, posizione del LED, tempo):
/// stesso risultato in anteprima e in Live, ripetibile (il "caso" è un hash deterministico).
extension EffectEngine {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func extended(_ p: EffectParams, context c: EffectContext, index i: Int, time t: Double,
                         u: Double, speed sp: Double, width w: Double) -> RGB {
        let pal = p.colors.isEmpty ? [RGB(r: 255, g: 255, b: 255)] : p.colors
        let c0 = p.primary, c1 = p.secondary
        let n = c.norm[i]
        let y01 = (n.y + 1) / 2
        let h = c.hash[i]
        let ledSeed = Int(h * 1_000_000)
        let tau = 2 * Double.pi

        switch p.kind {
        // MARK: Base
        case .gradient:
            return paletteLinear(pal, u)
        case .colorCycle:
            return palette(pal, t * sp * 0.5)
        case .breathe:
            let k = Int(floor(t * sp))
            let level = 0.5 - 0.5 * cos(tau * t * sp)
            return scale(pal[((k % pal.count) + pal.count) % pal.count], level)
        case .heartbeat:
            let ph = frac(t * sp * 0.8)
            let level = max(exp(-pow((ph - 0.05) / 0.04, 2)), 0.7 * exp(-pow((ph - 0.23) / 0.05, 2)))
            return mix(c1, c0, level)
        case .strobe:
            return frac(t * sp * 4) < 0.15 ? c0 : c1

        // MARK: Movimento
        case .gradientFlow:
            return palette(pal, u / max(w * 4, 0.2) - t * sp)
        case .bounce:
            let head = triangle(t * sp)
            let d = abs(u - head)
            let level = pow(max(0, 1 - d / (w * 0.6)), 2)
            return mix(c1, c0, level)
        case .dualScan:
            let a = triangle(t * sp), b = 1 - a
            let level = max(max(0, 1 - abs(u - a) / (w * 0.5)), max(0, 1 - abs(u - b) / (w * 0.5)))
            return mix(c1, c0, level)
        case .centerOut, .outsideIn:
            var d = abs(u - 0.5) * 2
            if p.kind == .outsideIn { d = 1 - d }
            let cycle = t * sp
            let k = Int(floor(cycle))
            let front = frac(cycle) * (1 + w)
            let level = min(1, max(0, (front - d) / w))
            let cur = pal[((k % pal.count) + pal.count) % pal.count]
            let prev = pal[(((k - 1) % pal.count) + pal.count) % pal.count]
            return mix(prev, cur, level)
        case .colorWipe:
            let cycle = t * sp
            let k = Int(floor(cycle))
            let front = frac(cycle) * (1 + w)
            let level = min(1, max(0, (front - u) / w))
            let cur = pal[((k % pal.count) + pal.count) % pal.count]
            let prev = pal[(((k - 1) % pal.count) + pal.count) % pal.count]
            return mix(prev, cur, level)
        case .rainbowMeteor:
            let head = frac(t * sp) * (1 + w)
            let d = head - u
            guard d >= 0 && d <= w else { return .black }
            return scale(hsv(frac(t * 0.07 + d * 0.8), 1, 1), pow(1 - d / w, 1.6))
        case .theaterChase:
            let ph = frac(u / max(w * 0.3, 0.02) - t * sp * 2)
            return ph < 0.33 ? c0 : scale(c1, 0.6)
        case .stripes:
            let idx = Int(floor(u / max(w * 0.25, 0.02) - t * sp * 0.5))
            return pal[((idx % pal.count) + pal.count) % pal.count]
        case .spiral:
            let ph = c.angle[i] * 2 + y01 * 0.6 - t * sp
            let level = pow(0.5 + 0.5 * cos(tau * ph), 3)
            return scale(palette(pal, ph * 0.5), 0.15 + 0.85 * level)
        case .beacon:
            var d = abs(c.angle[i] - frac(t * sp * 0.5))
            d = min(d, 1 - d)
            let level = pow(max(0, 1 - d / (w * 0.5)), 2)
            return mix(c1, c0, level)
        case .ripple:
            let v = 0.5 + 0.5 * sin(tau * (c.radius[i] / max(w, 0.05) - t * sp))
            return mix(c1, c0, pow(v, 4))
        case .powerDown:
            let progress = min(1, t * sp)
            let level = min(1, max(0, (u - progress * (1 + w) + w) / w))
            return scale(c0, level)

        // MARK: Natura
        case .fire:
            let flick = valueNoise(n.x * 3, y01 * 4 - t * sp * 3, n.z * 3)
            let heat = min(1, max(0, 1.15 - y01 * 1.25 + (flick - 0.5) * 0.9))
            return fireColor(heat, base: c0, tip: c1)
        case .candle:
            let f = valueNoise(h * 50, t * sp * 6, 0.5) * 0.6 + valueNoise(h * 13, t * sp * 17, 3.2) * 0.4
            return scale(c0, 0.45 + 0.55 * f)
        case .ocean:
            let v = valueNoise(n.x * 2 + t * sp * 0.4, n.z * 2, t * sp * 0.25)
            let wave = 0.5 + 0.5 * sin(tau * (u * 2 - t * sp * 0.5) + v * 3)
            return paletteLinear(pal, min(1, max(0, v * 0.7 + wave * 0.3)))
        case .aurora:
            let v = valueNoise(n.x * 1.5 + t * sp * 0.25, n.y * 2.5, t * sp * 0.12)
            let curtain = valueNoise(n.x * 4 + t * sp * 0.5, 7.7, n.z * 2)
            let level = min(1, (0.25 + 0.75 * curtain) * (0.4 + 0.6 * y01))
            return scale(paletteLinear(pal, v), level)
        case .plasma:
            let v = sin(n.x * 3 + t * sp * 2) + sin(n.z * 3 + t * sp * 1.3) + sin((n.x + n.y + n.z) * 2 + t * sp)
                + sin(c.radius[i] * 5 - t * sp * 1.7)
            return hsv(frac(v / 8 + t * sp * 0.1), 1, 1)
        case .lava:
            let v = valueNoise(n.x * 1.6 + t * sp * 0.15, n.y * 1.6, n.z * 1.6 - t * sp * 0.1)
            let level = min(1, max(0, (v - 0.25) * 1.6))
            return fireColor(level, base: c0, tip: c1)
        case .rain:
            let col = hash01(Int((n.x + 1) * 14), Int((n.z + 1) * 6), 3)
            let head = 1.15 - frac(t * sp * 0.8 + col) * 1.4
            let d = y01 - head
            let level = (d >= 0 && d < w) ? 1 - d / w : 0
            return mix(c1, c0, level)
        case .lightning:
            let slotT = t * sp * 1.5
            let slot = Int(floor(slotT))
            let ph = frac(slotT)
            guard hash01(slot, 11) < 0.45, ph < 0.3 else { return c1 }
            let flicker = frac(ph * 23) < 0.6 ? 1.0 : 0.25
            let origin = SIMD3(hash01(slot, 1) * 2 - 1, 0.5, hash01(slot, 2) * 2 - 1)
            let d = simd_distance(SIMD3(n.x, 0.5, n.z), origin)
            let level = max(0, 1 - d / (0.6 + w)) * flicker * (1 - ph / 0.3)
            return mix(c1, c0, level)
        case .starfield:
            let ph = frac(t * sp * 0.3 + h * 9.1)
            let star = hash01(ledSeed, 5) < 0.35 ? 1.0 : 0.0
            let level = star * (0.25 + 0.75 * pow(0.5 + 0.5 * sin(tau * ph), 3))
            return mix(c1, c0, level)

        // MARK: Festa
        case .sparkle:
            let slot = Int(floor(t * sp * 8 + h * 3))
            return hash01(slot, ledSeed) < w * 0.12 ? RGB(r: 255, g: 255, b: 255) : c1
        case .glitter:
            let tt = t * sp * 3 + h * 5
            let slot = Int(floor(tt))
            let fade = 1 - frac(tt)
            guard hash01(slot, ledSeed, 1) < 0.5 else { return .black }
            return scale(hsv(hash01(slot, ledSeed, 2), 1, 1), fade)
        case .confetti:
            let tt = t * sp + h * 7
            let slot = Int(floor(tt))
            guard hash01(slot, ledSeed, 3) < 0.3 else { return .black }
            let col = pal[Int(hash01(slot, ledSeed, 4) * Double(pal.count)) % pal.count]
            return scale(col, 1 - frac(tt))
        case .fireworks:
            var best = RGB.black
            var bestLevel = 0.0
            for b in 0..<3 {
                let tt = t * sp * 0.6 + Double(b) / 3
                let slot = Int(floor(tt)) * 3 + b
                let age = frac(tt)
                let origin = SIMD3(hash01(slot, 1) * 1.6 - 0.8, hash01(slot, 2) * 1.2 - 0.2, hash01(slot, 3) * 1.6 - 0.8)
                let d = simd_distance(n, origin)
                let ring = age * 1.3
                let level = exp(-pow((d - ring) / 0.12, 2)) * (1 - age)
                if level > bestLevel {
                    bestLevel = level
                    best = scale(hsv(hash01(slot, 7), 0.9, 1), min(1, level * 1.4))
                }
            }
            return best
        case .police:
            let side = u < 0.5
            let ph = frac(t * sp * 1.5)
            let on = side ? ph < 0.5 : ph >= 0.5
            let blink = frac(ph * 6) < 0.5
            return (on && blink) ? (side ? c0 : c1) : .black
        case .checker:
            let cell = max(w * 0.6, 0.1)
            let cx = Int(floor((n.x + 1) / cell)), cz = Int(floor((n.z + 1) / cell)), cy = Int(floor((n.y + 1) / cell))
            let beat = Int(floor(t * sp * 2))
            return ((cx + cy + cz + beat) % 2 == 0) ? c0 : c1
        case .disco:
            let cell = max(w * 0.8, 0.15)
            let cx = Int(floor((n.x + 1) / cell)), cz = Int(floor((n.z + 1) / cell)), cy = Int(floor((n.y + 1) / cell))
            let beat = Int(floor(t * sp * 2))
            return hsv(hash01(cx * 31 + cy * 7 + cz, beat), 1, 1)

        // MARK: Auto
        case .turnSignal:
            let ph = frac(t * sp * 1.2)
            if ph < 0.6 {
                return u <= ph / 0.6 ? c0 : c1
            }
            return ph < 0.8 ? c0 : c1
        case .hazard:
            return frac(t * sp * 1.4) < 0.5 ? c0 : c1
        case .welcome:
            let tt = t * sp
            if tt < 1 {
                let level = min(1, max(0, (tt * (1 + w) - (1 - u)) / w))
                return scale(c1, level)
            }
            let k = min(1, tt - 1)
            let glow = 0.75 + 0.25 * cos(tau * (tt - 1) * 0.3)
            return scale(mix(c1, c0, k), glow)
        case .brake:
            let rear = 1 - u
            let level = pow(rear, 1.5) * (0.6 + 0.4 * (0.5 + 0.5 * cos(tau * t * sp)))
            return mix(c1, c0, level)

        default:
            return c0
        }
    }

    // MARK: Utilità

    /// Tavolozza ciclica: 0…1 percorre tutti i colori e torna al primo.
    static func palette(_ pal: [RGB], _ x: Double) -> RGB {
        guard pal.count > 1 else { return pal.first ?? .black }
        let f = frac(x) * Double(pal.count)
        let i = Int(f) % pal.count
        return mix(pal[i], pal[(i + 1) % pal.count], f - floor(f))
    }

    /// Tavolozza lineare: 0 = primo colore, 1 = ultimo.
    static func paletteLinear(_ pal: [RGB], _ x: Double) -> RGB {
        guard pal.count > 1 else { return pal.first ?? .black }
        let f = min(max(x, 0), 1) * Double(pal.count - 1)
        let i = min(Int(f), pal.count - 2)
        return mix(pal[i], pal[i + 1], f - Double(i))
    }

    /// Onda triangolare 0→1→0 con periodo 1.
    static func triangle(_ x: Double) -> Double {
        let f = frac(x)
        return f < 0.5 ? f * 2 : 2 - f * 2
    }

    static func fireColor(_ heat: Double, base: RGB, tip: RGB) -> RGB {
        if heat < 0.35 { return scale(base, heat / 0.35 * 0.6) }
        if heat < 0.75 { return mix(scale(base, 0.6), base, (heat - 0.35) / 0.4) }
        return mix(base, tip, (heat - 0.75) / 0.25)
    }

    /// Hash deterministico in [0, 1).
    static func hash01(_ a: Int, _ b: Int = 0, _ c: Int = 0) -> Double {
        var x = UInt64(bitPattern: Int64(a)) &* 0x9E3779B97F4A7C15
        x ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2AE3D27D4EB4F
        x ^= UInt64(bitPattern: Int64(c)) &* 0x165667B19E3779F9
        x ^= x >> 31
        x = x &* 0xBF58476D1CE4E5B9
        x ^= x >> 27
        return Double(x % 1_000_003) / 1_000_003
    }

    /// Rumore a valori 3D liscio in [0, 1].
    static func valueNoise(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y)), zi = Int(floor(z))
        let xf = x - floor(x), yf = y - floor(y), zf = z - floor(z)
        func s(_ v: Double) -> Double { v * v * (3 - 2 * v) }
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        func v(_ dx: Int, _ dy: Int, _ dz: Int) -> Double { hash01(xi + dx, yi + dy, zi + dz) }
        let u = s(xf), vv = s(yf), w = s(zf)
        let x00 = lerp(v(0, 0, 0), v(1, 0, 0), u), x10 = lerp(v(0, 1, 0), v(1, 1, 0), u)
        let x01 = lerp(v(0, 0, 1), v(1, 0, 1), u), x11 = lerp(v(0, 1, 1), v(1, 1, 1), u)
        return lerp(lerp(x00, x10, vv), lerp(x01, x11, vv), w)
    }
}
