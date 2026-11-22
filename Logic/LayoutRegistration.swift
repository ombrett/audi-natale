import Foundation
import simd

/// Allinea una scansione al progetto usando l'identità dei LED: lo stesso (centralina, pixel) esiste
/// sia nella scansione sia nel layout di progetto, quindi l'allineamento non deve indovinare il verso
/// dell'auto. Stima rotazione attorno all'asse verticale, traslazione e scala con minimi quadrati,
/// scartando i LED montati diversamente dal progetto (che restano nella posizione misurata).
enum LayoutRegistration {
    struct Pair { let scan: SIMD3<Double>; let design: SIMD3<Double> }

    struct Fit: Equatable {
        var alignment: CarAlignment
        var used: Int            // pixel usati per la stima finale
        var total: Int           // pixel presenti in entrambe le mappe
        var rms: Double          // scarto medio dei pixel usati (m)
        var matchRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }
        /// Abbastanza pixel e scarto contenuto: l'allineamento è affidabile.
        var isGood: Bool { used >= 12 && rms < 0.15 && matchRatio >= 0.4 && abs(alignment.scale - 1) < 0.15 }

        var summary: String {
            String(format: "%d di %d pixel coincidono col progetto · scarto medio %.0f cm · scala %.3f", used, total, rms * 100, alignment.scale)
        }
    }

    /// Coppie per pixel logico: baricentro delle copie fisiche nella scansione e nel progetto
    /// (il baricentro delle due file a Y è lo stesso punto in entrambe, qualunque copia sia quale).
    static func pairs(scan: [EffectPoint], design: [EffectPoint]) -> [Pair] {
        func centroids(_ pts: [EffectPoint]) -> [LEDKey: SIMD3<Double>] {
            var sum: [LEDKey: (SIMD3<Double>, Int)] = [:]
            for p in pts { let v = sum[p.key] ?? (.zero, 0); sum[p.key] = (v.0 + p.position, v.1 + 1) }
            return sum.mapValues { $0.0 / Double($0.1) }
        }
        let a = centroids(scan), b = centroids(design)
        return a.keys.sorted().compactMap { k in b[k].map { Pair(scan: a[k]!, design: $0) } }
    }

    /// Minimi quadrati: car = scala · R(yaw) · (p − offset), con R rotazione attorno a y.
    static func solve(_ pairs: [Pair]) -> CarAlignment? {
        guard pairs.count >= 3 else { return nil }
        let n = Double(pairs.count)
        let ca = pairs.reduce(SIMD3<Double>.zero) { $0 + $1.scan } / n
        let cb = pairs.reduce(SIMD3<Double>.zero) { $0 + $1.design } / n
        var sxx = 0.0, sxz = 0.0, aa = 0.0
        for p in pairs {
            let a = p.scan - ca, b = p.design - cb
            sxx += a.x * b.x + a.z * b.z
            sxz += a.x * b.z - a.z * b.x
            aa += simd_length_squared(a)
        }
        guard aa > 1e-9 else { return nil }
        let phi = atan2(sxz, sxx)
        let c = cos(phi), s = sin(phi)
        var proj = 0.0
        for p in pairs {
            let a = p.scan - ca, b = p.design - cb
            let ra = SIMD3(c * a.x - s * a.z, a.y, s * a.x + c * a.z)
            proj += simd_dot(ra, b)
        }
        let scale = proj / aa
        guard scale > 0.5, scale < 2 else { return nil }
        // car = scale·R·(p − o)  ⇒  o = ca − R⁻¹·cb / scale
        let ib = cb / scale
        let rInv = SIMD3(c * ib.x + s * ib.z, ib.y, -s * ib.x + c * ib.z)
        return CarAlignment(yaw: -phi, offset: ca - rInv, scale: scale)
    }

    /// Stima robusta: ripete la stima tenendo i pixel con scarto ≤ max(3 × mediana, 8 cm).
    static func fit(scan: [EffectPoint], design: [EffectPoint]) -> Fit? {
        let all = pairs(scan: scan, design: design)
        guard var a = solve(all) else { return nil }
        var used = all
        for _ in 0..<5 {
            let res = all.map { simd_distance(a.toCar($0.scan), $0.design) }
            let med = res.sorted()[res.count / 2]
            let limit = max(3 * med, 0.08)
            let keep = zip(all, res).filter { $0.1 <= limit }.map { $0.0 }
            guard keep.count >= 3, let next = solve(keep) else { break }
            a = next
            used = keep
        }
        let rms = (used.map { simd_distance_squared(a.toCar($0.scan), $0.design) }.reduce(0, +) / Double(used.count)).squareRoot()
        // Conteggio finale con soglia fissa: quanti pixel sono davvero dove li prevede il progetto.
        let close = all.filter { simd_distance(a.toCar($0.scan), $0.design) <= max(0.08, 2 * rms) }.count
        return Fit(alignment: a, used: close, total: all.count, rms: rms)
    }
}

/// Adatta le animazioni pre-calcolate (colori per indirizzo del progetto) ai LED scansionati:
/// ogni LED fisico prende il colore dell'indirizzo di progetto più vicino alla sua posizione reale.
/// Le due copie a Y dello stesso pixel ricevono la media, perché fisicamente hanno un solo colore.
enum ClipRetarget {
    struct Source: Hashable { let controller: Int; let pixel: Int }

    static func table(scanned: [EffectPoint], design: [LEDLayoutImport.Point]) -> [LEDKey: [Source]] {
        guard !design.isEmpty else { return [:] }
        var out: [LEDKey: [Source]] = [:]
        for p in scanned {
            var best = design[0], bestD = Double.infinity
            for d in design {
                let dd = simd_distance_squared(d.position, p.position)
                if dd < bestD { bestD = dd; best = d }
            }
            out[p.key, default: []].append(Source(controller: best.controller, pixel: best.pixel))
        }
        return out
    }

    static func colors(_ rows: [[RGB]], table: [LEDKey: [Source]]) -> [LEDKey: RGB] {
        var out: [LEDKey: RGB] = [:]
        for (key, sources) in table {
            var r = 0, g = 0, b = 0, n = 0
            for s in sources where rows.indices.contains(s.controller) && rows[s.controller].indices.contains(s.pixel) {
                let c = rows[s.controller][s.pixel]
                r += Int(c.r); g += Int(c.g); b += Int(c.b); n += 1
            }
            if n > 0 { out[key] = RGB(r: UInt8((r + n / 2) / n), g: UInt8((g + n / 2) / n), b: UInt8((b + n / 2) / n)) }
        }
        return out
    }
}
