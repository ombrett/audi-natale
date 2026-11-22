import SwiftUI

/// Schermate delle milestone 3 e 4. Non simulano funzioni non ancora implementate:
/// mostrano cosa faranno e da cosa dipendono.
struct PlannedScreen: View {
    let title: String
    let milestone: String
    let systemImage: String
    let summary: String
    let steps: [String]
    let dependency: String

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Milestone \(milestone) — non implementata", systemImage: systemImage) {
                    Text(summary).font(.subheadline)
                    Label(dependency, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
                Card(title: "Previsto", systemImage: "list.number") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.accent).frame(width: 18)
                            Text(s).font(.caption)
                        }
                    }
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle(title)
    }
}

struct AnimationsView: View {
    var body: some View {
        PlannedScreen(
            title: "Animations", milestone: "4", systemImage: "sparkles",
            summary: "Animazioni generate dall'app con frequenza limitata alla velocità reale misurata del collegamento BLE, mostrata a schermo.",
            steps: [
                "Misura dei tempi di upload e degli ack su ogni controller.",
                "Limite automatico dei fotogrammi al secondo.",
                "Effetti nativi del controller (SGLS/MULT) dove bastano.",
            ],
            dependency: "Richiede l'editor (Milestone 4)."
        )
    }
}
