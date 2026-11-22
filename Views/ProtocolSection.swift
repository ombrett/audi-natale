import SwiftUI

/// Verifica di compatibilità e primo obiettivo sperimentale (LED 1 rosso → blu).
struct ProtocolSection: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var ideal: IdealController
    @EnvironmentObject var settings: AppSettings

    @State private var pendingAction: PendingAction?
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let run: () -> Void
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                checklistCard
                documentedCard
                pixelCard
                resultCard
                hypothesesCard
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .onReceive(ticker) { now = $0 }   // aggiorna il conto alla rovescia post-connessione
        .alert(item: $pendingAction) { action in
            Alert(title: Text(action.title), message: Text(action.message),
                  primaryButton: .destructive(Text("Invia")) { action.run() },
                  secondaryButton: .cancel(Text("Annulla")))
        }
    }

    // MARK: Card

    private var checklistCard: some View {
        Card(title: "Verifica compatibilità", systemImage: "checklist") {
            ForEach(ideal.checklist) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.ok ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.ok ? Theme.ok : Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline)
                        Text(item.detail).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Text("Nessuna scrittura parte da sola: ogni passo richiede un tuo tocco. Dopo una riconnessione le notifiche vanno riattivate.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .id(now)
    }

    private var documentedCard: some View {
        Card(title: "Comandi documentati", systemImage: "doc.text.magnifyingglass") {
            Text("Byte identici alle catture pubblicate dell'app vendor. Non ancora confermati su questo controller finché non arriva l'ack.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Button("1 · Iscriviti a …9601") { ideal.subscribeNotifications() }
                .buttonStyle(AccentButtonStyle(filled: false))
                .enabled(ble.phase == .ready)
            Button("2 · Leggi versione (VE 00 / VE 01)") {
                confirmIfNew("VE", title: "Leggi versione",
                             message: "Invia VE 00 e VE 01 cifrati su …9600. È una richiesta di sola lettura documentata; la risposta decifrata conferma chiave AES e protocollo.") {
                    ideal.queryVersions()
                }
            }
            .buttonStyle(AccentButtonStyle())
            .enabled(ideal.transportReady)
            HStack(spacing: 10) {
                Button("Accendi") {
                    confirmIfNew("TURN", title: "TURN 01", message: "Comando documentato (cattura 8none1/glowmote).") { ideal.power(true) }
                }
                Button("Spegni") {
                    confirmIfNew("TURN", title: "TURN 00", message: "Comando documentato (cattura 8none1/glowmote).") { ideal.power(false) }
                }
            }
            .buttonStyle(AccentButtonStyle(filled: false))
            .enabled(ideal.transportReady && ble.isSettled)
        }
    }

    private var pixelCard: some View {
        Card(title: "Primo obiettivo: LED 1", systemImage: "lightbulb.led") {
            if !ideal.pixelTestEnabled {
                Text("Disabilitato finché la verifica non è completa (notifiche attive, risposta VE decifrata, attesa post-connessione).")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            Stepper("Luminosità DIY: \(settings.diyBrightness)%", value: $settings.diyBrightness, in: 1...100, step: 5)
                .font(.subheadline)
            HStack(spacing: 10) {
                Button {
                    confirmIfNew("DOOD", title: "LED 1 rosso", message: pixelMessage("rosso")) { ideal.setFirstPixel(.red) }
                } label: { Label("Rosso", systemImage: "circle.fill") }
                    .buttonStyle(AccentButtonStyle(color: Color(red: 1, green: 0.25, blue: 0.25)))
                Button {
                    confirmIfNew("DOOD", title: "LED 1 blu", message: pixelMessage("blu")) { ideal.setFirstPixel(.blue) }
                } label: { Label("Blu", systemImage: "circle.fill") }
                    .buttonStyle(AccentButtonStyle(color: Color(red: 0.3, green: 0.5, blue: 1)))
            }
            .enabled(ideal.pixelTestEnabled)
            HStack(spacing: 10) {
                Button("Esci, mantieni") { ideal.exitDIY(keepDrawing: true) }
                Button("Esci, ripristina") { ideal.exitDIY(keepDrawing: false) }
            }
            .buttonStyle(AccentButtonStyle(filled: false))
            .enabled(ideal.pixelTestEnabled && ideal.diyActive)
            Text("Sequenza: DEN 00 (entra in DIY e azzera la tela) → DOOD indice 0. LED fisico 1 = indice 0. \"Esci, mantieni\" invia DSTOP 01.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private var resultCard: some View {
        Card(title: "Risposte", systemImage: "arrow.down.message") {
            row("Ultimo esito", ideal.lastResult ?? "—")
            row("Ultima notifica", ideal.lastReply ?? "—")
            row("Ack sessione", ideal.sessionAcks.isEmpty ? "—" : ideal.sessionAcks.joined(separator: ", "))
            row("Confermati su \(ideal.deviceName)", ideal.confirmedTags.isEmpty ? "—" : ideal.confirmedTags.sorted().joined(separator: ", "))
            if let p = ideal.pending {
                Label("In attesa di \(p.tag)OK…", systemImage: "hourglass").font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private var hypothesesCard: some View {
        Card(title: "Ipotesi da confermare", systemImage: "questionmark.diamond") {
            VStack(alignment: .leading, spacing: 6) {
                bullet("Che ISP-B0717F (HW 22.12.02.1, FW 23.09.12.1) usi la stessa chiave AES: lo conferma la risposta VE.")
                bullet("Che DOOD su questo firmware abbia lo stesso layout (indice big-endian ai byte 6–7): lo conferma l'ack DOODOK e l'accensione del solo LED 1.")
                bullet("Limite pixel: il firmware TR2309 analizzato ha buffer da 400 LED; 1600 LED su un solo controller non sono dimostrati. L'app non invia indici ≥ 400.")
                bullet("FD00/FD01/FD02 e AE00/AE01 (OTA) non vengono mai scritti.")
            }
        }
    }

    // MARK: Helper

    private func pixelMessage(_ color: String) -> String {
        let first = ideal.diyActive ? "" : "DEN 00 (azzera la tela) e poi "
        return "Invia \(first)DOOD indice 0 \(color), luminosità \(settings.diyBrightness)%. Layout documentato da catture su ISP-50542B; primo invio su questo controller."
    }

    /// Conferma esplicita finché il controller non ha mai risposto a quel tag.
    private func confirmIfNew(_ tag: String, title: String, message: String, run: @escaping () -> Void) {
        if ideal.confirmedTags.contains(tag) {
            run()
        } else {
            pendingAction = PendingAction(title: title, message: message + "\n\nIl controller non ha ancora confermato \(tag): procedere?", run: run)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(v).font(Theme.monoSmall).textSelection(.enabled)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(Theme.accent)
            Text(s).font(.caption)
        }
    }
}
