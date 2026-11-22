import SwiftUI

/// Pulsante "Collega e verifica" riutilizzato in Dashboard, Editor, Scan e Animations.
struct QuickConnectView: View {
    @EnvironmentObject var ideal: IdealController
    @EnvironmentObject var ble: BLEManager
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ideal.canDraw {
                Label(ideal.quickMessage ?? "Collegato e verificato", systemImage: "checkmark.seal.fill")
                    .font(.subheadline).foregroundStyle(Theme.ok)
            } else if ideal.quickStep != .idle {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text(ideal.quickStep.label).font(.subheadline)
                    Spacer()
                    Button("Annulla") { ideal.cancelQuickConnect() }.font(.caption)
                }
            } else {
                Button {
                    ideal.quickConnect()
                } label: { Label("Collega e verifica", systemImage: "bolt.horizontal.circle.fill") }
                    .buttonStyle(AccentButtonStyle())
                    .enabled(ble.bluetoothState == .poweredOn)
                if let m = ideal.quickMessage {
                    Text(m).font(.caption).foregroundStyle(Theme.warning)
                } else if !compact {
                    Text("Trova la centralina, attende l'assestamento, attiva le notifiche e verifica il protocollo. Chiudi prima l'app iDeal LED.")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
