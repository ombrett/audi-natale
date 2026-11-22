import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ideal: IdealController
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Stepper("Luminosità LED: \(settings.diyBrightness)%", value: $settings.diyBrightness, in: 1...100, step: 5)
                Stepper("Finestra di invio: \(settings.sendWindow)", value: $settings.sendWindow, in: 1...8)
            } header: { Text("Invio alle centraline") } footer: {
                Text("Valgono per Effetti, Live e Scansione. Finestra 6 = circa 72 comandi/s per centralina, misurato su ISP-B0717F.")
            }
            Section {
                NavigationLink { BluetoothLabView() } label: { Label("Bluetooth Lab (diagnostica, HEX, log)", systemImage: "antenna.radiowaves.left.and.right") }
                NavigationLink { EditorView() } label: { Label("Editor 2D singola centralina", systemImage: "square.grid.4x3.fill") }
                NavigationLink { ScanView() } label: { Label("Scansione 2D singola centralina", systemImage: "camera.viewfinder") }
                NavigationLink { LEDMapView() } label: { Label("Mappe 2D", systemImage: "map") }
                NavigationLink { AnimationsView() } label: { Label("Effetti interni della centralina", systemImage: "cpu") }
            } header: { Text("Strumenti avanzati") } footer: {
                Text("Strumenti della prima versione: lavorano su una centralina alla volta tramite il Bluetooth Lab, con un collegamento separato da quello della sezione Centraline.")
            }
            Section("Bluetooth Lab · singola centralina") {
                TextField("Nome BLE atteso", text: $settings.targetName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Stepper("LED configurati: \(settings.ledCount)", value: $settings.ledCount, in: 1...IdealProtocol.maxSafeLEDs)
                Text("Limite \(IdealProtocol.maxSafeLEDs): buffer pixel del firmware TR2309 analizzato. Indici oltre il limite non vengono mai inviati.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Section("Connessione") {
                Toggle("Riconnessione automatica", isOn: $settings.autoReconnect)
                Toggle("Mostra solo ISP-/IDL-", isOn: $settings.showOnlyIdealDevices)
                Stepper("Attesa post-connessione: \(Int(settings.settleSeconds)) s", value: $settings.settleSeconds, in: 0...10, step: 1)
            }
            Section("DIY") {
                Stepper("Luminosità: \(settings.diyBrightness)%", value: $settings.diyBrightness, in: 1...100, step: 5)
            }
            Section("Verifiche sul dispositivo") {
                let tags = ideal.confirmedTags.sorted()
                Text(tags.isEmpty ? "Nessun comando confermato su \(ideal.deviceName)." : "Confermati su \(ideal.deviceName): \(tags.joined(separator: ", "))")
                    .font(.footnote)
                Button("Azzera conferme", role: .destructive) { confirmReset = true }
            }
            Section("Info") {
                Text("Protocollo: AES-128-ECB iDeal/Winkison, fonti 8none1/idealLED e KyleJamesWalker/glowmote. Nessuna operazione OTA, firmware o reset.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                Text("Log esportati: app File › Audi Light Studio › Logs.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Settings")
        .confirmationDialog("Azzerare i comandi confermati?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Azzera", role: .destructive) { settings.resetConfirmedTags(for: ideal.deviceName) }
        }
    }
}
