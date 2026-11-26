import SwiftUI

/// Stato e avvio dell'analisi Adaptive Y sulla mappa attiva.
struct AdaptiveYStatus: View {
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var adaptiveY: AdaptiveYStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Adaptive Y").font(.headline)
                Spacer()
                if let avg = adaptiveY.averageScore, !adaptiveY.isRunning { ScoreChip(score: avg) }
            }
            if adaptiveY.isRunning {
                ProgressView(value: adaptiveY.progress)
                Text("Analisi: \(adaptiveY.currentName) · \(Int(adaptiveY.progress * 100))%").font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
            } else if adaptiveY.analyzedCount > 0 {
                let low = adaptiveY.reports.values.filter { $0.original.score < AdaptiveY.variantThreshold }.count
                Text("\(adaptiveY.analyzedCount) preset analizzati sulla mappa attiva · \(low) poco compatibili · \(adaptiveY.variants.count) varianti ottimizzate")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Misura per ogni preset quanto le due copie di ogni indirizzo vorrebbero colori diversi sulla tua mappa, sceglie il colore condiviso migliore e crea varianti dei preset meno compatibili.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Button(adaptiveY.analyzedCount > 0 ? "Rianalizza" : "Analizza compatibilità Y") {
                if let e = player.adaptive { adaptiveY.analyzeAll(e) }
            }
            .buttonStyle(AccentButtonStyle(filled: adaptiveY.analyzedCount == 0))
            .disabled(adaptiveY.isRunning || player.adaptive == nil)
            .accessibilityIdentifier("adaptive-y-analyze")
        }
        .padding(.vertical, 4)
    }
}

/// Mappa 3D: gemelli a Y misurati sulla mappa e analisi Adaptive Y.
struct TwinCard: View {
    @EnvironmentObject var carMaps: CarMapStore
    @EnvironmentObject var adaptiveY: AdaptiveYStore
    @State private var stats: TwinStats?
    @State private var key = ""

    var body: some View {
        Card(title: "Gemelli a Y", systemImage: "arrow.triangle.branch") {
            if let s = stats {
                HStack {
                    stat("\(s.twins)", "con 2 copie")
                    stat(String(format: "%.2f m", s.medianDistance), "distanza mediana")
                    stat(String(format: "%.2f m", s.maxDistance), "massima")
                }
                Text("\(s.farApart) indirizzi con copie a più di 50 cm · \(s.differentZones) con copie in zone diverse · \(s.singles) con una sola copia rilevata")
                    .font(.caption).foregroundStyle(s.farApart > 0 ? Theme.textPrimary : Theme.textSecondary)
                Text("Le copie possono stare ovunque (serpentina, lati diversi): la compatibilità si misura sui colori lungo tutta l'animazione, non sulla distanza.")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Hairline()
            AdaptiveYStatus()
        }
        .onAppear(perform: refresh)
        .onChange(of: carMaps.activeID) { _ in refresh() }
        .onChange(of: carMaps.active?.leds.count ?? 0) { _ in refresh() }
    }

    private func refresh() {
        guard let m = carMaps.active else { stats = nil; return }
        let k = "\(m.id)-\(m.leds.count)-\(m.overriddenCount)-\(m.alignment.yaw)"
        guard k != key else { return }
        key = k
        stats = TwinStats.compute(m, design: ProjectLayout.bundled?.points)
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(Theme.monoBody)
            Text(l).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
