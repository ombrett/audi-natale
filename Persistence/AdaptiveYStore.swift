import Foundation

/// Analisi Adaptive Y della mappa attiva: punteggi, piani per indirizzo e varianti ottimizzate.
/// Calcolata in background, salvata su disco con l'impronta della mappa (si invalida da sola se cambia).
final class AdaptiveYStore: ObservableObject {
    @Published private(set) var reports: [String: AdaptiveY.PresetReport] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentName = ""
    @Published private(set) var fingerprint = ""
    @Published private(set) var lastRun: Date?

    private var token = UUID()
    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("adaptive-y.json")
    }()

    private struct Saved: Codable {
        var fingerprint: String
        var date: Date
        var reports: [String: AdaptiveY.PresetReport]
    }

    static let variantSuffix = "~y"

    /// La mappa (motore) è cambiata: ricarica l'analisi salvata se corrisponde, altrimenti la azzera.
    func attach(_ engine: AdaptiveEffects.Engine?) {
        guard let engine else { token = UUID(); reports = [:]; fingerprint = ""; isRunning = false; return }
        let fp = AdaptiveY.fingerprint(engine)
        guard fp != fingerprint else { return }
        token = UUID()
        isRunning = false
        fingerprint = fp
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data), s.fingerprint == fp {
            reports = s.reports
            lastRun = s.date
        } else {
            reports = [:]
            lastRun = nil
        }
    }

    /// Analizza tutti i preset in background (originali + varianti per i meno compatibili).
    func analyzeAll(_ engine: AdaptiveEffects.Engine, presets: [AdaptiveEffects.Preset] = AdaptiveEffects.presets) {
        let t = UUID()
        token = t
        fingerprint = AdaptiveY.fingerprint(engine)
        isRunning = true
        progress = 0
        let fp = fingerprint
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var out: [String: AdaptiveY.PresetReport] = [:]
            for (i, p) in presets.enumerated() {
                guard let self, self.token == t else { return }
                DispatchQueue.main.async { if self.token == t { self.currentName = p.name } }
                out[p.id] = AdaptiveY.report(engine, p)
                let snapshot = out
                DispatchQueue.main.async {
                    guard self.token == t else { return }
                    self.reports = snapshot
                    self.progress = Double(i + 1) / Double(presets.count)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.token == t else { return }
                self.isRunning = false
                self.currentName = ""
                self.lastRun = Date()
                if let data = try? JSONEncoder().encode(Saved(fingerprint: fp, date: Date(), reports: out)) {
                    try? data.write(to: self.url, options: .atomic)
                }
            }
        }
    }

    // MARK: Accesso ai piani

    static func baseID(_ id: String) -> String { id.hasSuffix(variantSuffix) ? String(id.dropLast(variantSuffix.count)) : id }
    static func isVariant(_ id: String) -> Bool { id.hasSuffix(variantSuffix) }

    /// Analisi da usare per un preset in riproduzione (originale o variante).
    func analysis(for id: String) -> AdaptiveY.Analysis? {
        guard let r = reports[Self.baseID(id)] else { return nil }
        return Self.isVariant(id) ? r.variant : r.original
    }

    /// Varianti ottimizzate disponibili per la mappa attiva, come preset riproducibili.
    var variants: [AdaptiveEffects.Preset] {
        AdaptiveEffects.presets.compactMap { p in
            guard reports[p.id]?.variant != nil else { return nil }
            return AdaptiveEffects.Preset(id: p.id + Self.variantSuffix, name: p.name + " · Y", duration: p.duration, loop: p.loop, effect: p.effect)
        }
    }

    var analyzedCount: Int { reports.count }
    var averageScore: Int? {
        guard !reports.isEmpty else { return nil }
        return Int((Double(reports.values.map { $0.best.score }.reduce(0, +)) / Double(reports.count)).rounded())
    }
}
