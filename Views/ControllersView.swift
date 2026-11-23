import SwiftUI

struct ControllersView: View {
    @EnvironmentObject var hub: ControllerHub
    @EnvironmentObject var player: EffectPlayer
    @State private var showAdd = false
    @State private var editing: ControllerConfig?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summaryCard
                ForEach(Array(hub.orderedLinks.enumerated()), id: \.element.id) { i, link in
                    ControllerCard(link: link, letter: controllerLetter(i)) { editing = link.config }
                }
                if hub.controllers.isEmpty {
                    Text("Aggiungi le centraline ISP una alla volta. Chiudi l'app iDeal LED: ogni centralina accetta una sola connessione.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).padding()
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Centraline")
        .toolbar {
            Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
        }
        .sheet(isPresented: $showAdd) { AddControllerSheet() }
        .sheet(item: $editing) { c in EditControllerSheet(config: c) }
    }

    private var summaryCard: some View {
        Card(title: "Impianto", systemImage: "network") {
            // Stato reale per lettera: A, B, C, D nell'ordine della lista.
            if !hub.controllers.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(hub.orderedLinks.enumerated()), id: \.element.id) { i, link in
                        VStack(spacing: 4) {
                            Text(controllerLetter(i)).font(Theme.monoBody.weight(.semibold))
                                .foregroundStyle(link.isReady ? Theme.accent : Theme.textSecondary)
                            Circle().fill(link.isReady ? Theme.accent : (link.state.isBusy ? Theme.warning : Theme.surfaceHigh))
                                .frame(width: 8, height: 8)
                            Text(link.isReady ? "pronta" : (link.config.isPlaceholder ? "assoc." : (link.state.isBusy ? "…" : "offline")))
                                .font(Theme.monoSmall).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityIdentifier("controllers-letters")
                Hairline()
            }
            Text(situation).font(.caption).foregroundStyle(hub.readyLinks.isEmpty ? Theme.textSecondary : Theme.textPrimary)
            HStack {
                stat("\(hub.controllers.count)", "centraline")
                stat("\(hub.readyLinks.count)", "pronte")
                stat("\(hub.totalLEDs)", "pixel logici")
            }
            HStack(spacing: 10) {
                Button("Collega tutte") { hub.connectAll() }
                    .buttonStyle(AccentButtonStyle())
                    .enabled(!hub.controllers.isEmpty && hub.bluetoothState == .poweredOn)
                Button("Scollega") { hub.disconnectAll() }
                    .buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false))
                    .frame(width: 110)
            }
            Toggle("Riconnessione automatica", isOn: $hub.autoReconnect).font(.subheadline)
            if hub.bluetoothState != .poweredOn {
                Text(hub.bluetoothState.label).font(.caption).foregroundStyle(Theme.danger)
            }
            Text("Alla connessione ogni centralina viene verificata (notifiche + versione VE) prima di accettare comandi. Il limite di sicurezza è 400 LED per centralina.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    /// Zero, parziale, tutte; Bluetooth spento; disconnessione durante il Live.
    private var situation: String {
        let total = hub.enabledControllers.count, ready = hub.readyLinks.count
        var s: String
        if hub.bluetoothState != .poweredOn {
            s = "Bluetooth non disponibile (\(hub.bluetoothState.label.lowercased())). Puoi lavorare offline: modello, mappa e anteprima degli effetti funzionano."
        } else if total == 0 {
            s = "Nessuna centralina configurata. Offline puoi comunque provare gli effetti sul modello."
        } else if ready == 0 {
            s = "0/\(total) collegate: lo Studio lavora in anteprima, all'auto non arriva nulla."
        } else if ready < total {
            s = "\(ready)/\(total) collegate: il Live invia solo alle centraline pronte."
        } else {
            s = "\(ready)/\(total) collegate."
        }
        if player.mode == .live && player.isPlaying && ready < total && total > 0 {
            s += " Live in corso: le centraline scollegate non ricevono, le altre continuano."
        }
        return s
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title2.weight(.semibold)).foregroundStyle(Theme.accent)
            Text(l).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ControllerCard: View {
    @EnvironmentObject var hub: ControllerHub
    @ObservedObject var link: ControllerLink
    var letter: String = ""
    var onEdit: () -> Void
    @State private var identifying = false

    var statusColor: Color {
        switch link.state {
        case .ready: return Theme.ok
        case .failed: return Theme.danger
        case .offline: return Theme.textSecondary
        default: return Theme.warning
        }
    }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Text(letter).font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(link.isReady ? Theme.accent : Theme.textSecondary)
                    .frame(width: 30)
                RoundedRectangle(cornerRadius: 2).fill(ControllerPalette.color(link.config.tint)).frame(width: 3, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(link.config.name).font(.headline)
                        if !link.config.enabled { Badge(text: "DISATTIVA", color: Theme.textSecondary) }
                        if link.config.isPlaceholder { Badge(text: "DA ASSOCIARE", color: Theme.warning) }
                    }
                    Text("\(link.config.isPlaceholder ? "nessun dispositivo" : link.config.bleName) · \(link.config.ledCount) pixel · \(link.config.copiesPerPixel == 2 ? "a Y (2 LED/pixel)" : "\(link.config.copiesPerPixel) LED/pixel")")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button(action: onEdit) { Image(systemName: "slider.horizontal.3") }
            }
            HStack(spacing: 8) {
                StatusDot(color: statusColor, pulsing: link.state.isBusy)
                Text(link.state.label).font(.subheadline)
                Spacer()
                if let r = link.rssi { Text("\(r) dBm").font(Theme.monoSmall).foregroundStyle(Theme.textSecondary) }
            }
            if !link.versions.isEmpty || link.model != nil {
                Text([link.model, link.versions.joined(separator: " · ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
            }
            if let t = link.transfer, t.isRunning {
                ProgressView(value: Double(t.done), total: Double(max(t.total, 1))).tint(Theme.accent)
            }
            if let r = link.lastRate { Text(String(format: "Ultimo invio: %.0f comandi/s", r)).font(.caption2).foregroundStyle(Theme.textSecondary) }
            if let m = link.lastMessage { Text(m).font(.caption).foregroundStyle(Theme.warning) }
            HStack(spacing: 8) {
                if link.isReady || link.state.isBusy {
                    Button("Scollega") { hub.disconnect(link.id) }.buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false))
                } else {
                    Button("Collega") { hub.connect(link.id) }.buttonStyle(AccentButtonStyle(filled: false))
                        .enabled(link.config.enabled && hub.bluetoothState == .poweredOn)
                }
                Button(identifying ? "…" : "Identifica") { identify() }
                    .buttonStyle(AccentButtonStyle(filled: false))
                    .enabled(link.isReady && !identifying)
            }
        }
    }

    /// Accende tutti i LED della centralina nel suo colore per 2 s, poi li spegne.
    private func identify() {
        identifying = true
        let n = link.config.ledCount
        link.apply(target: [RGB](repeating: ControllerPalette.rgb(link.config.tint), count: n))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            link.apply(target: [RGB](repeating: .black, count: n))
            identifying = false
        }
    }
}

struct AddControllerSheet: View {
    @EnvironmentObject var hub: ControllerHub
    @Environment(\.dismiss) private var dismiss
    @State private var ledCount = 200
    /// Segnaposto del layout a cui associare il prossimo dispositivo (nil = nuova centralina).
    @State private var target: UUID?

    var body: some View {
        NavigationStack {
            List {
                if !hub.placeholders.isEmpty {
                    Section {
                        Picker("Associa a", selection: $target) {
                            Text("Nuova centralina").tag(UUID?.none)
                            ForEach(hub.placeholders) { c in Text(c.name).tag(UUID?.some(c.id)) }
                        }
                    } footer: {
                        Text("Il layout di progetto ha creato centraline da associare: scegli a quale pacco corrisponde il dispositivo che tocchi. Usa \"Identifica\" dopo per controllare.")
                    }
                }
                if target == nil {
                    Section {
                        Stepper("Pixel per centralina: \(ledCount)", value: $ledCount, in: 1...IdealProtocol.maxSafeLEDs, step: 10)
                    } footer: {
                        Text("Con due file a Y sulla stessa linea dati conta i pixel di UNA fila (es. 200).")
                    }
                }
                Section(hub.isScanning ? "Ricerca…" : "Centraline trovate") {
                    let configured = Set(hub.controllers.compactMap { $0.peripheralID })
                    let names = Set(hub.controllers.map { $0.bleName })
                    ForEach(hub.found.values.sorted { $0.rssi > $1.rssi }) { d in
                        let added = configured.contains(d.id) || names.contains(d.name)
                        Button {
                            if let t = target {
                                hub.bind(t, to: d)
                                target = hub.placeholders.first?.id
                            } else {
                                hub.add(device: d, ledCount: ledCount)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "lightbulb.led.wide.fill").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading) {
                                    Text(d.name)
                                    Text("\(d.rssi) dBm").font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                if added { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                            }
                        }
                        .disabled(added)
                    }
                    if hub.found.isEmpty && !hub.isScanning {
                        Text("Nessuna centralina ISP-/IDL- trovata.").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Aggiungi centralina")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(hub.isScanning ? "Stop" : "Cerca") { hub.isScanning ? hub.stopScan() : hub.startScan() }
                }
            }
            .onAppear { target = hub.placeholders.first?.id; hub.startScan() }
            .onDisappear { hub.stopScan() }
        }
        .preferredColorScheme(.dark)
    }
}

struct EditControllerSheet: View {
    @EnvironmentObject var hub: ControllerHub
    @Environment(\.dismiss) private var dismiss
    @State var config: ControllerConfig
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Identità") {
                    TextField("Nome", text: $config.name)
                    LabeledContent("Nome BLE", value: config.bleName)
                    LabeledContent("ID app", value: String(config.id.uuidString.prefix(8)))
                    Picker("Colore", selection: $config.tint) {
                        ForEach(0..<ControllerPalette.colors.count, id: \.self) { i in
                            Label("Colore \(i + 1)", systemImage: "circle.fill").foregroundStyle(ControllerPalette.color(i)).tag(i)
                        }
                    }
                }
                Section {
                    Stepper("Pixel: \(config.ledCount)", value: $config.ledCount, in: 1...IdealProtocol.maxSafeLEDs, step: 10)
                    Stepper("LED fisici per pixel: \(config.copiesPerPixel)", value: $config.copiesPerPixel, in: 1...4)
                    Toggle("Attiva", isOn: $config.enabled)
                } header: { Text("LED") } footer: {
                    Text("Il numero di pixel deve corrispondere a quello impostato nell'app iDeal LED. LED fisici per pixel = 2 con due file a Y: avranno sempre lo stesso colore.")
                }
                Section {
                    Button("Rimuovi centralina", role: .destructive) { confirmRemove = true }
                }
            }
            .navigationTitle(config.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salva") { hub.update(config); dismiss() } }
            }
            .confirmationDialog("Rimuovere \(config.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Rimuovi", role: .destructive) { hub.remove(config.id); dismiss() }
            } message: {
                Text("I LED di questa centralina nelle mappe salvate resteranno, ma non saranno più comandabili.")
            }
        }
        .preferredColorScheme(.dark)
    }
}
