import Foundation
import simd

// MARK: - Adaptive Y
//
// Con il cablaggio a Y le due copie di un indirizzo ricevono sempre lo stesso RGB, ma possono stare
// ovunque sull'auto (serpentina, lati non speculari, altezze diverse). Questo motore:
//  • calcola per ogni preset il colore "ideale" di ogni copia fisica (posizioni reali della mappa);
//  • misura il conflitto cromatico tra le copie in tutta l'animazione (OKLab, non distanza fisica);
//  • confronta più strategie per il colore condiviso e sceglie, per indirizzo, quella con l'errore
//    percepito minore sull'intera animazione (scelta fissa: niente sfarfallio da cambio di strategia);
//  • assegna un punteggio di compatibilità 0–100;
//  • ottimizza direzione, frequenza spaziale, fase e ampiezza dell'onda e genera varianti dei preset
//    meno compatibili.
// Anteprima e Live usano lo stesso risultato: un solo RGB per indirizzo, quello davvero inviato.

enum OKLab {
    @inline(__always) static func lin(_ v: Double) -> Double {
        let c = v / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    @inline(__always) static func gam(_ v: Double) -> Double {
        let c = max(0, min(1, v))
        return (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255
    }

    /// sRGB 0…255 → OKLab (L 0…1).
    static func from(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab → sRGB 0…255 arrotondato e limitato alla gamma.
    static func to(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return SIMD3(gam(r).rounded(), gam(g).rounded(), gam(b).rounded())
    }

    /// Differenza percepita (ΔE OKLab × 100: ~2 appena visibile, >20 colori diversi).
    static func deltaE(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { simd_distance(a, b) * 100 }
}

enum AdaptiveY {
    typealias C = SIMD3<Double>
    typealias Sample = AdaptiveEffects.Sample

    /// Strategie per il colore condiviso di un indirizzo con più copie.
    enum Strategy: Int, CaseIterable, Codable {
        case brightest = 0          // regola classica: copia più luminosa
        case perceptualMean = 1     // media in OKLab: minimo errore quadratico percepito
        case highlightWeighted = 2  // media OKLab pesata sulla luminosità: conserva i picchi (scintille, scie)
        case midpoint = 3           // effetto valutato nel punto medio tra le copie
        case copyA = 4              // segue sempre la prima copia
        case copyB = 5              // segue sempre la seconda copia

        var label: String {
            switch self {
            case .brightest: return "Più luminosa"
            case .perceptualMean: return "Media percettiva"
            case .highlightWeighted: return "Media che conserva i picchi"
            case .midpoint: return "Punto medio"
            case .copyA: return "Segue copia 1"
            case .copyB: return "Segue copia 2"
            }
        }
    }

    /// Trasformazione dell'onda: direzione (nel piano lunghezza–altezza), frequenza spaziale,
    /// fase spaziale (frazione della lunghezza dell'auto) e ampiezza della modulazione di colore.
    struct WaveParams: Codable, Equatable {
        var angle: Double = 0        // radianti
        var frequency: Double = 1
        var phase: Double = 0
        var amplitude: Double = 1

        static let identity = WaveParams()
        var isIdentity: Bool { self == .identity }

        /// Quanto la variante si allontana dal preset originale (in unità ΔE, per l'ottimizzazione).
        var deviation: Double {
            6 * abs(angle) / (Double.pi / 2) + 6 * abs(log(frequency)) + 4 * abs(phase) + 15 * (1 - amplitude)
        }

        var summary: String {
            String(format: "direzione %+.0f°, frequenza ×%.2f, fase %+.2f, ampiezza %.0f%%", angle * 180 / .pi, frequency, phase, amplitude * 100)
        }

        /// Campione trasformato: coordinate in metri, rotazione attorno al centro dell'auto, scala e spostamento
        /// lungo la nuova direzione di propagazione.
        func apply(_ s: Sample) -> Sample {
            if angle == 0 && frequency == 1 && phase == 0 { return s }
            let X = (s.x - 0.5) * 4.0, Y = s.h * 1.2 - 0.6
            let c = cos(angle), n = sin(angle)
            var along = c * X + n * Y
            let across = -n * X + c * Y
            along = along * frequency + phase * 4.0
            var q = s
            q.x = along / 4.0 + 0.5
            q.h = (across + 0.6) / 1.2
            return q
        }
    }

    // MARK: Colore condiviso

    /// Colore condiviso secondo la strategia. `midpoint` richiede l'effetto e i campioni.
    static func shared(_ ideals: [C], strategy: Strategy, midpoint: () -> C) -> C {
        guard ideals.count > 1 else { return ideals.first ?? .zero }
        switch strategy {
        case .brightest:
            var best = ideals[0]
            for c in ideals.dropFirst() where max(c.x, c.y, c.z) > max(best.x, best.y, best.z) { best = c }
            return best
        case .perceptualMean:
            return OKLab.to(ideals.map(OKLab.from).reduce(.zero, +) / Double(ideals.count))
        case .highlightWeighted:
            let labs = ideals.map(OKLab.from)
            var sum = C.zero, w = 0.0
            for l in labs { let k = 0.05 + l.x * l.x; sum += l * k; w += k }
            return OKLab.to(sum / w)
        case .midpoint:
            return midpoint()
        case .copyA:
            return ideals[0]
        case .copyB:
            return ideals[1]
        }
    }

    /// Errore percepito di un colore condiviso rispetto agli ideali delle copie: ΔE medio più una
    /// penalità per i picchi persi (una scintilla spenta si nota più di un fondo un po' più chiaro).
    static func error(ideals: [C], shared s: C) -> Double {
        error(labs: ideals.map(OKLab.from), sharedLab: OKLab.from(s))
    }

    static func error(labs: [C], sharedLab ls: C) -> Double {
        guard labs.count > 1 else { return 0 }
        var sum = 0.0, maxL = 0.0
        for l in labs {
            sum += OKLab.deltaE(l, ls)
            maxL = max(maxL, l.x)
        }
        return sum / Double(labs.count) + 0.5 * max(0, maxL - ls.x) * 100
    }

    /// Conflitto tra le copie (ΔE massimo tra coppie): 0 = vorrebbero lo stesso colore.
    static func conflict(_ ideals: [C]) -> Double {
        guard ideals.count > 1 else { return 0 }
        let labs = ideals.map(OKLab.from)
        var m = 0.0
        for i in 0..<labs.count { for j in (i + 1)..<labs.count { m = max(m, OKLab.deltaE(labs[i], labs[j])) } }
        return m
    }

    // MARK: Fotogrammi

    /// Colori ideali di ogni copia (per indirizzo) a un istante, con la trasformazione d'onda applicata.
    static func ideals(_ engine: AdaptiveEffects.Engine, _ p: AdaptiveEffects.Preset, u: Double, params: WaveParams,
                       only: Set<Int>? = nil, offsets: [Int]) -> [[[C]]] {
        var out: [[[C]]] = []
        out.reserveCapacity(engine.addresses.count)
        var all = C.zero, n = 0.0
        for (ci, list) in engine.addresses.enumerated() {
            var row: [[C]] = []
            row.reserveCapacity(list.count)
            for (k, samples) in list.enumerated() {
                if let only, !only.contains(offsets[ci] + k) { row.append([]); continue }
                let cs = samples.map { p.effect(u, params.apply($0)) }
                for c in cs { all += c; n += 1 }
                row.append(cs)
            }
            out.append(row)
        }
        if params.amplitude < 1 && n > 0 {
            // Ampiezza: modulazione ridotta attorno al colore medio del fotogramma.
            let mean = all / n, a = params.amplitude
            out = out.map { $0.map { $0.map { c in
                let v = mean + (c - mean) * a
                return C(v.x.rounded(), v.y.rounded(), v.z.rounded())
            } } }
        }
        return out
    }

    /// Indice globale dell'indirizzo (centralina per centralina) → per i piani.
    static func offsets(_ engine: AdaptiveEffects.Engine) -> [Int] {
        var o: [Int] = [], acc = 0
        for list in engine.addresses { o.append(acc); acc += list.count }
        return o
    }

    /// Fotogramma riproducibile: un RGB per indirizzo, scelto con la strategia del piano.
    static func frame(_ engine: AdaptiveEffects.Engine, _ p: AdaptiveEffects.Preset, elapsed: Double,
                      params: WaveParams = .identity, strategy: (Int) -> Strategy) -> [[RGB]] {
        let u = AdaptiveEffects.Engine.phase(p, elapsed: elapsed)
        let off = offsets(engine)
        let ideal = ideals(engine, p, u: u, params: params, offsets: off)
        return ideal.enumerated().map { ci, row in
            row.enumerated().map { k, cs -> RGB in
                guard !cs.isEmpty else { return .black }
                let samples = engine.addresses[ci][k]
                let s = shared(cs, strategy: strategy(off[ci] + k)) {
                    let c = midColor(p, u: u, samples: samples, params: params)
                    return c
                }
                return RGB(r: UInt8(max(0, min(255, s.x))), g: UInt8(max(0, min(255, s.y))), b: UInt8(max(0, min(255, s.z))))
            }
        }
    }

    static func midColor(_ p: AdaptiveEffects.Preset, u: Double, samples: [Sample], params: WaveParams) -> C {
        guard var m = samples.first else { return .zero }
        let n = Double(samples.count)
        m.x = samples.map { $0.x }.reduce(0, +) / n
        m.h = samples.map { $0.h }.reduce(0, +) / n
        m.r = samples.map { $0.r }.reduce(0, +) / n
        return p.effect(u, params.apply(m))
    }

    // MARK: Analisi

    struct Analysis: Codable, Equatable {
        var presetID: String
        var params: WaveParams
        var score: Int                       // 0…100 con le strategie scelte
        var classicScore: Int                // 0…100 con la regola classica (più luminosa)
        var meanConflict: Double             // ΔE medio tra le copie prima di condividere
        var residual: Double                 // errore percepito medio dopo la scelta
        var strategyErrors: [Double]         // errore medio usando una sola strategia ovunque (per confronto)
        var strategyUse: [Int]               // quante coppie usano ciascuna strategia
        var plan: [Int]                      // strategia per indirizzo globale (−1 = copia unica)
        var twins: Int
        var worst: [Int]                     // indirizzi globali con l'errore più alto

        func strategy(_ global: Int) -> Strategy {
            guard plan.indices.contains(global), let s = Strategy(rawValue: plan[global]) else { return .highlightWeighted }
            return s
        }
    }

    static func score(_ residual: Double) -> Int { Int((100 * exp(-max(0, residual) / 15)).rounded()) }

    /// Istanti campionati su tutta l'animazione (loop completo o fino alla fine).
    static func times(_ p: AdaptiveEffects.Preset, count: Int) -> [Double] {
        (0..<count).map { p.duration * (Double($0) + 0.5) / Double(count) }
    }

    /// Analizza un preset sulla mappa: conflitto, errore di ogni strategia, scelta per indirizzo, punteggio.
    static func analyze(_ engine: AdaptiveEffects.Engine, _ p: AdaptiveEffects.Preset, params: WaveParams = .identity,
                        frames: Int = 24, stride: Int = 1) -> Analysis {
        let off = offsets(engine)
        let total = (off.last ?? 0) + (engine.addresses.last?.count ?? 0)
        var twins: [(ci: Int, k: Int, g: Int)] = []
        for (ci, list) in engine.addresses.enumerated() {
            for (k, s) in list.enumerated() where s.count > 1 { twins.append((ci, k, off[ci] + k)) }
        }
        let sampled = Swift.stride(from: 0, to: twins.count, by: max(1, stride)).map { twins[$0] }
        let only = Set(sampled.map { $0.g })
        let S = Strategy.allCases.count
        var err = Array(repeating: Array(repeating: 0.0, count: S), count: sampled.count)
        var conflictSum = 0.0
        for t in times(p, count: frames) {
            let u = AdaptiveEffects.Engine.phase(p, elapsed: t)
            let ideal = ideals(engine, p, u: u, params: params, only: only, offsets: off)
            for (i, tw) in sampled.enumerated() {
                let cs = ideal[tw.ci][tw.k]
                let labs = cs.map(OKLab.from)
                var cmax = 0.0
                for x in 0..<labs.count { for y in (x + 1)..<labs.count { cmax = max(cmax, OKLab.deltaE(labs[x], labs[y])) } }
                conflictSum += cmax
                let samples = engine.addresses[tw.ci][tw.k]
                var mid: C?
                for s in Strategy.allCases {
                    if s == .copyB && cs.count < 2 { err[i][s.rawValue] = .infinity; continue }
                    let sh = shared(cs, strategy: s) {
                        if mid == nil { mid = midColor(p, u: u, samples: samples, params: params) }
                        return mid!
                    }
                    err[i][s.rawValue] += error(labs: labs, sharedLab: OKLab.from(sh))
                }
            }
        }
        let F = Double(frames)
        var plan = Array(repeating: -1, count: total)
        var use = Array(repeating: 0, count: S)
        var residuals: [(Double, Int)] = []
        for (i, tw) in sampled.enumerated() {
            let best = (0..<S).min { err[i][$0] < err[i][$1] }!
            plan[tw.g] = best
            use[best] += 1
            residuals.append((err[i][best] / F, tw.g))
        }
        // Indirizzi non campionati (stride > 1): strategia più usata.
        let fallback = use.indices.max { use[$0] < use[$1] } ?? Strategy.highlightWeighted.rawValue
        for tw in twins where plan[tw.g] < 0 { plan[tw.g] = fallback }
        let n = Double(max(sampled.count, 1))
        let residual = residuals.map { $0.0 }.reduce(0, +) / n
        let perStrategy = (0..<S).map { s in sampled.indices.map { min(err[$0][s], 1e9) }.reduce(0, +) / n / F }
        return Analysis(presetID: p.id, params: params,
                        score: sampled.isEmpty ? 100 : score(residual),
                        classicScore: sampled.isEmpty ? 100 : score(perStrategy[Strategy.brightest.rawValue]),
                        meanConflict: sampled.isEmpty ? 0 : conflictSum / n / F,
                        residual: residual, strategyErrors: perStrategy, strategyUse: use, plan: plan,
                        twins: twins.count, worst: residuals.sorted { $0.0 > $1.0 }.prefix(10).map { $0.1 })
    }

    // MARK: Ottimizzazione dell'onda

    struct Optimized {
        var params: WaveParams
        var objective: Double
        var evaluations: Int
    }

    /// Ricerca per coordinate su direzione, frequenza, fase e ampiezza: minimizza errore residuo +
    /// scostamento dal preset originale. Valuta su meno fotogrammi e un sottoinsieme di coppie.
    static func optimize(_ engine: AdaptiveEffects.Engine, _ p: AdaptiveEffects.Preset, frames: Int = 12, stride: Int = 2,
                         rounds: Int = 2) -> Optimized {
        let angles = [-90.0, -60, -45, -30, -15, 0, 15, 30, 45, 60, 90].map { $0 * Double.pi / 180 }
        let freqs = [0.5, 0.7, 0.85, 1.0, 1.25, 1.5]
        let phases = [-0.25, -0.125, 0, 0.125, 0.25]
        let amps = [1.0, 0.85, 0.7]
        var best = WaveParams.identity
        var evals = 0
        func objective(_ w: WaveParams) -> Double {
            evals += 1
            return analyze(engine, p, params: w, frames: frames, stride: stride).residual + w.deviation
        }
        var bestObj = objective(best)
        for _ in 0..<rounds {
            var improved = false
            for a in angles where a != best.angle { var w = best; w.angle = a; let o = objective(w); if o < bestObj - 1e-6 { bestObj = o; best = w; improved = true } }
            for f in freqs where f != best.frequency { var w = best; w.frequency = f; let o = objective(w); if o < bestObj - 1e-6 { bestObj = o; best = w; improved = true } }
            for ph in phases where ph != best.phase { var w = best; w.phase = ph; let o = objective(w); if o < bestObj - 1e-6 { bestObj = o; best = w; improved = true } }
            for am in amps where am != best.amplitude { var w = best; w.amplitude = am; let o = objective(w); if o < bestObj - 1e-6 { bestObj = o; best = w; improved = true } }
            if !improved { break }
        }
        return Optimized(params: best, objective: bestObj, evaluations: evals)
    }

    /// Risultato completo per un preset: analisi dell'originale e, se conviene, variante ottimizzata.
    struct PresetReport: Codable, Equatable {
        var original: Analysis
        var variant: Analysis?
        var best: Analysis { variant ?? original }
    }

    static let variantThreshold = 85      // sotto questo punteggio si cerca una variante
    static let variantMinGain = 5         // la variante deve migliorare almeno di 5 punti

    static func report(_ engine: AdaptiveEffects.Engine, _ p: AdaptiveEffects.Preset) -> PresetReport {
        let original = analyze(engine, p)
        guard original.score < variantThreshold, original.twins > 0 else { return PresetReport(original: original, variant: nil) }
        let opt = optimize(engine, p)
        guard !opt.params.isIdentity else { return PresetReport(original: original, variant: nil) }
        let v = analyze(engine, p, params: opt.params)
        return PresetReport(original: original, variant: v.score >= original.score + variantMinGain ? v : nil)
    }

    /// Impronta della mappa: cambia se cambiano punti, posizioni, zone o allineamento (stabile tra avvii).
    static func fingerprint(_ engine: AdaptiveEffects.Engine) -> String {
        var acc: UInt64 = 1469598103934665603
        func mix(_ v: Int) { acc = (acc ^ UInt64(bitPattern: Int64(v))) &* 1099511628211 }
        for (ci, list) in engine.addresses.enumerated() {
            for (k, s) in list.enumerated() {
                mix(ci * 1000 + k); mix(s.count)
                for x in s {
                    mix(Int((x.x * 1000).rounded())); mix(Int((x.h * 1000).rounded())); mix(Int((x.r * 1000).rounded())); mix(x.zone.order)
                }
            }
        }
        return String(acc, radix: 36)
    }
}
