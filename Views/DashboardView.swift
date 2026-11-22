import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var ideal: IdealController
    @EnvironmentObject var settings: AppSettings
    @Binding var tab: RootView.Tab

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                Card(title: "Controller", systemImage: "cpu") {
                    info("Atteso", settings.targetName)
                    info("Connesso", ble.connectedName ?? "—")
                    info("Modello (2901)", ideal.modelString ?? "—")
                    info("Versioni", ideal.versions.isEmpty ? "—" : ideal.versions.sorted { $0.key < $1.key }.map { $0.value }.joined(separator: " · "))
                    info("Protocollo", ideal.protocolConfirmed ? "AES iDeal confermato" : "da verificare")
                    Button("Apri Bluetooth Lab") { tab = .lab }
                        .buttonStyle(AccentButtonStyle())
                }
                Card(title: "Milestone", systemImage: "flag.checkered") {
                    milestone("1", "Bluetooth Lab, diagnostica, log, HEX, build CI", state: "Implementata — da provare sull'auto")
                    milestone("2", "Protocollo verificato, primo pixel, più pixel, disegni", state: "Encoder pronti e testati sui vettori; manca la prova fisica")
                    milestone("3", "Mappatura con fotocamera", state: "Non iniziata")
                    milestone("4", "Editor avanzato, animazioni, 1600 LED", state: "Non iniziata")
                }
                Card(title: "Schermate", systemImage: "square.grid.2x2") {
                    NavigationLink("LED Map") { LEDMapView() }
                    NavigationLink("Animations") { AnimationsView() }
                    Button("Scan") { tab = .scan }
                    Button("Editor") { tab = .editor }
                }
                .font(.subheadline)
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Audi Light Studio")
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Theme.surfaceHigh, Theme.background], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    // Striscia LED stilizzata
                    HStack(spacing: 5) {
                        ForEach(0..<24, id: \.self) { i in
                            Capsule()
                                .fill(i == 0 && ideal.sessionAcks.contains("DOOD") ? Theme.accent : Theme.accent.opacity(0.08 + Double(i % 6) * 0.03))
                                .frame(width: 6, height: 16)
                        }
                    }
                    .padding(.top, 22), alignment: .top
                )
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
            VStack(alignment: .leading, spacing: 6) {
                Text("Audi A1 · 2020").font(.caption).foregroundStyle(Theme.textSecondary)
                Text("1600 LED previsti").font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    StatusDot(color: ble.phase == .ready ? Theme.ok : Theme.textSecondary, pulsing: ble.phase == .ready)
                    Text(ble.phase.label).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(18)
        }
        .frame(height: 170)
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(v).font(Theme.mono).multilineTextAlignment(.trailing)
        }
    }

    private func milestone(_ n: String, _ title: String, state: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(.headline).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(state).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
