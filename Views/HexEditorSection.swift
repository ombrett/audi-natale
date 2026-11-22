import SwiftUI
import CoreBluetooth

/// Editor HEX con validazione, selezione esplicita della caratteristica e del tipo di scrittura,
/// classificazione documentato / sperimentale / bloccato e conferma per i comandi sperimentali.
struct HexEditorSection: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var settings: AppSettings
    @Binding var writeTarget: String

    @State private var text = ""
    @State private var encoding: PayloadEncoding = .plaintextEncryptInApp
    @State private var writeType: CBCharacteristicWriteType = .withoutResponse
    @State private var confirmExperimental = false
    @State private var result: String?

    struct Preset: Identifiable {
        var id: String { name }
        let name: String
        let plain: [UInt8]
    }

    private var presets: [Preset] {
        var list = [
            Preset(name: "VE 00 — versione PCB", plain: IdealProtocol.versionQuery(second: false)),
            Preset(name: "VE 01 — versione firmware", plain: IdealProtocol.versionQuery(second: true)),
            Preset(name: "TURN 01 — accendi", plain: IdealProtocol.power(true)),
            Preset(name: "TURN 00 — spegni", plain: IdealProtocol.power(false)),
            Preset(name: "DEN 00 — entra in DIY", plain: IdealProtocol.diyEnter()),
            Preset(name: "DSTOP 01 — esci, mantieni", plain: IdealProtocol.diyExit(keepDrawing: true)),
            Preset(name: "DSTOP 00 — esci, ripristina", plain: IdealProtocol.diyExit(keepDrawing: false)),
        ]
        if let red = try? IdealProtocol.diyPixel(index: 0, color: .red, brightness: settings.diyBrightness) {
            list.append(Preset(name: "DOOD LED 1 rosso", plain: red))
        }
        if let blue = try? IdealProtocol.diyPixel(index: 0, color: .blue, brightness: settings.diyBrightness) {
            list.append(Preset(name: "DOOD LED 1 blu", plain: blue))
        }
        return list
    }

    private var target: GATTCharacteristicInfo? { ble.characteristicInfo(writeTarget) }
    private var role: CharacteristicRole { .of(writeTarget) }
    private var isEncryptedChannel: Bool { role == .command || role == .rhythm }

    private var parsed: Result<[UInt8], Hex.ParseError> { Hex.parse(text) }
    private var bytes: [UInt8]? { try? parsed.get() }

    private var verdict: SafetyVerdict? {
        guard let bytes else { return nil }
        return CommandSafety.evaluate(bytes: bytes, role: role, encoding: isEncryptedChannel ? encoding : .plaintextEncryptInApp,
                                      ledCount: settings.ledCount)
    }

    /// Byte che finiranno davvero sulla caratteristica.
    private var wireBytes: [UInt8]? {
        guard let bytes else { return nil }
        if isEncryptedChannel && encoding == .plaintextEncryptInApp { return IdealCrypto.encrypt(bytes) }
        return bytes
    }

    private var allCharacteristics: [GATTCharacteristicInfo] { ble.services.flatMap { $0.characteristics } }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                targetCard
                inputCard
                verdictCard
                sendCard
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .onChange(of: writeTarget) { _ in fixWriteType() }
        .onAppear(perform: fixWriteType)
        .alert("Comando sperimentale", isPresented: $confirmExperimental) {
            Button("Invia comunque", role: .destructive) { send() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text((verdict?.reasons ?? []).joined(separator: "\n") + "\n\nQuesto pacchetto non è mai stato catturato su un controller reale. Inviarlo?")
        }
    }

    // MARK: Card

    private var targetCard: some View {
        Card(title: "Caratteristica di scrittura", systemImage: "scope") {
            if allCharacteristics.isEmpty {
                Text("Non connesso.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            ForEach(allCharacteristics.filter { $0.canWrite || $0.canWriteWithoutResponse }) { c in
                Button {
                    writeTarget = c.uuid
                } label: {
                    HStack {
                        Image(systemName: writeTarget == c.uuid ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.uuid).font(Theme.monoSmall)
                            Text(c.role.label).font(.caption2)
                        }
                        Spacer()
                        if !c.role.writable { Image(systemName: "lock.fill").foregroundStyle(Theme.danger) }
                    }
                    .foregroundStyle(c.role.writable ? Theme.textPrimary : Theme.textSecondary)
                }
                .disabled(!c.role.writable)
            }
            if let target {
                Picker("Tipo di scrittura", selection: $writeType) {
                    if target.canWriteWithoutResponse { Text("Without Response").tag(CBCharacteristicWriteType.withoutResponse) }
                    if target.canWrite { Text("With Response").tag(CBCharacteristicWriteType.withResponse) }
                }
                .pickerStyle(.segmented)
                Text("Supportati: \(target.propertyNames.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var inputCard: some View {
        Card(title: "Pacchetto HEX", systemImage: "number") {
            if isEncryptedChannel {
                Picker("Formato", selection: $encoding) {
                    ForEach(PayloadEncoding.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            TextEditor(text: $text)
                .font(Theme.mono)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceHigh))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            switch parsed {
            case .success(let b):
                Text("\(b.count) byte · ASCII: \(Hex.ascii(b))").font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
            case .failure(let e):
                Text(text.isEmpty ? "Inserisci i byte, es. 05 54 55 52 4E 01 + zeri" : e.description)
                    .font(.caption).foregroundStyle(text.isEmpty ? Theme.textSecondary : Theme.danger)
            }
            if role == .command {
                Menu {
                    ForEach(presets) { p in
                        Button(p.name) {
                            encoding = .plaintextEncryptInApp
                            text = Hex.string(p.plain)
                        }
                    }
                } label: {
                    Label("Inserisci comando documentato", systemImage: "text.badge.plus").font(.subheadline)
                }
            }
        }
    }

    private var verdictCard: some View {
        Card(title: "Validazione", systemImage: "shield.lefthalf.filled") {
            if let v = verdict {
                HStack {
                    Badge(text: v.level.label.uppercased(), color: Theme.color(for: v.level))
                    if let tag = v.tag { Text(tag).font(Theme.mono) }
                }
                ForEach(v.reasons, id: \.self) { Text($0).font(.caption) }
                if let plain = v.plaintext, isEncryptedChannel {
                    Text("In chiaro: \(Hex.string(plain))").font(Theme.monoSmall).textSelection(.enabled)
                }
                if let wire = wireBytes {
                    Text("Sul canale: \(Hex.string(wire))").font(Theme.monoSmall).foregroundStyle(Theme.accent).textSelection(.enabled)
                }
            } else {
                Text("—").foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var sendCard: some View {
        Card {
            Button {
                guard let v = verdict else { return }
                switch v.level {
                case .documented: send()
                case .experimental: confirmExperimental = true
                case .blocked: break
                }
            } label: {
                Label(sendLabel, systemImage: "paperplane.fill")
            }
            .buttonStyle(AccentButtonStyle(color: verdict.map { Theme.color(for: $0.level) } ?? Theme.accent))
            .enabled(canSend)
            if let result {
                Text(result).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var sendLabel: String {
        switch verdict?.level {
        case .documented?: return "Invia (documentato)"
        case .experimental?: return "Invia (sperimentale, chiede conferma)"
        case .blocked?: return "Bloccato"
        case nil: return "Invia"
        }
    }

    private var canSend: Bool {
        ble.phase == .ready && ble.isSettled && target != nil && role.writable && verdict != nil && verdict?.level != .blocked
    }

    private func fixWriteType() {
        guard let t = target else { return }
        if writeType == .withoutResponse && !t.canWriteWithoutResponse { writeType = .withResponse }
        if writeType == .withResponse && !t.canWrite { writeType = .withoutResponse }
    }

    private func send() {
        guard let wire = wireBytes, let v = verdict, v.level != .blocked else { return }
        if let plain = v.plaintext, isEncryptedChannel {
            ble.log.add(.event, writeTarget, bytes: plain, "HEX editor, in chiaro [\(v.level.label)]")
        }
        let err = ble.write(wire, to: writeTarget, type: writeType, note: "HEX editor \(v.tag ?? "") [\(v.level.label)]")
        result = err ?? "Inviato \(wire.count) byte su \(target?.displayName ?? writeTarget)."
    }
}
