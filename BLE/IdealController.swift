import Foundation
import CoreBluetooth

/// Livello di protocollo iDeal ISP sopra BLEManager: verifica di compatibilità, invio dei comandi
/// documentati con policy di sicurezza, attesa degli ack, test del primo pixel.
final class IdealController: ObservableObject {
    struct CheckItem: Identifiable {
        let id: String
        let title: String
        let ok: Bool
        let detail: String
    }

    struct PendingAck {
        let tag: String
        let sentAt: Date
    }

    @Published private(set) var versions: [Int: String] = [:]
    @Published private(set) var sessionAcks: [String] = []
    @Published private(set) var lastReply: String?
    @Published private(set) var lastResult: String?
    @Published private(set) var diyActive = false
    @Published private(set) var pending: PendingAck?

    let ble: BLEManager
    let settings: AppSettings
    private var lastVersionIndex = 0
    private var ackTimeout: DispatchWorkItem?

    init(ble: BLEManager, settings: AppSettings) {
        self.ble = ble
        self.settings = settings
        ble.onValue = { [weak self] uuid, bytes in self?.handleValue(uuid, bytes) }
        ble.onDisconnect = { [weak self] in self?.resetSession() }
    }

    private var log: PacketLog { ble.log }

    var deviceName: String { ble.connectedName ?? settings.targetName }

    /// Modello letto dal descrittore 2901 di …9600 (es. "TR2411R003-07"), se presente.
    var modelString: String? {
        ble.characteristicInfo(IdealUUID.command)?.descriptors
            .first(where: { $0.uuid == IdealUUID.userDescriptionDescriptor })?.value
    }

    var confirmedTags: Set<String> { settings.confirmedTags(for: deviceName) }

    // MARK: Verifica di compatibilità

    var checklist: [CheckItem] {
        let cmd = ble.characteristicInfo(IdealUUID.command)
        let notify = ble.characteristicInfo(IdealUUID.notify)
        let bulk = ble.characteristicInfo(IdealUUID.bulk)
        let name = ble.connectedName ?? "-"
        return [
            CheckItem(id: "conn", title: "Connesso e GATT scoperto", ok: ble.phase == .ready,
                      detail: ble.phase.label),
            CheckItem(id: "name", title: "Nome ISP-/IDL-", ok: IdealUUID.isIdealName(ble.connectedName),
                      detail: name == settings.targetName ? "\(name) (atteso)" : name),
            CheckItem(id: "9600", title: "…9600 comandi con Write Without Response", ok: cmd?.canWriteWithoutResponse == true,
                      detail: cmd?.propertyNames.joined(separator: ", ") ?? "assente"),
            CheckItem(id: "9601", title: "…9601 con Notify", ok: notify?.canNotify == true,
                      detail: notify?.propertyNames.joined(separator: ", ") ?? "assente"),
            CheckItem(id: "960A", title: "…960A frame bulk", ok: bulk != nil,
                      detail: bulk?.propertyNames.joined(separator: ", ") ?? "assente"),
            CheckItem(id: "notify", title: "Notifiche …9601 attive", ok: notify?.isNotifying == true,
                      detail: notify?.isNotifying == true ? "attive" : "premi \"Iscriviti a …9601\""),
            CheckItem(id: "model", title: "Modello (descrittore 2901)", ok: modelString != nil,
                      detail: modelString ?? "non letto (informativo)"),
            CheckItem(id: "aes", title: "Risposta VE decifrata con la chiave AES", ok: protocolConfirmed,
                      detail: versions.isEmpty ? "invia \"Leggi versione\"" : versions.sorted { $0.key < $1.key }.map { "VE \($0.key): \($0.value)" }.joined(separator: " · ")),
            CheckItem(id: "settle", title: "Attesa post-connessione (\(Int(settings.settleSeconds)) s)", ok: ble.isSettled,
                      detail: ble.isSettled ? "ok" : "il controller riapplica il suo stato dopo la connessione"),
        ]
    }

    /// La risposta a VE, decifrata con la chiave pubblicata, è una stringa "V…": chiave e famiglia di
    /// protocollo sono confermate su questo controller.
    var protocolConfirmed: Bool { !versions.isEmpty }

    var transportReady: Bool {
        ble.phase == .ready
            && ble.characteristicInfo(IdealUUID.command)?.canWriteWithoutResponse == true
            && ble.characteristicInfo(IdealUUID.notify)?.isNotifying == true
    }

    /// I pulsanti del primo pixel si abilitano solo qui.
    var pixelTestEnabled: Bool { transportReady && protocolConfirmed && ble.isSettled }

    // MARK: Azioni

    func subscribeNotifications() {
        ble.setNotify(true, for: IdealUUID.notify)
    }

    func queryVersions() {
        guard transportReady else { lastResult = "Prima connetti e attiva le notifiche su …9601."; return }
        lastVersionIndex = 0
        send(IdealProtocol.versionQuery(second: false), label: "VE 00 (versione PCB)", expect: "VE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.lastVersionIndex = 1
            self.send(IdealProtocol.versionQuery(second: true), label: "VE 01 (versione firmware)", expect: "VE")
        }
    }

    func power(_ on: Bool) {
        send(IdealProtocol.power(on), label: on ? "TURN 01 (accendi)" : "TURN 00 (spegni)", expect: "TURN")
    }

    /// LED fisico 1 = indice 0. Entra in DIY (DEN 00 azzera la tela → gli altri LED restano spenti),
    /// poi invia DOOD per il solo indice 0.
    func setFirstPixel(_ color: RGB) {
        guard pixelTestEnabled else { lastResult = "Verifica di compatibilità incompleta."; return }
        let brightness = min(max(settings.diyBrightness, 0), 100)
        let packet: [UInt8]
        do {
            packet = try IdealProtocol.diyPixel(index: 0, color: color, brightness: brightness)
        } catch {
            lastResult = "\(error)"
            return
        }
        let name = color == .red ? "rosso" : color == .blue ? "blu" : Hex.string([color.r, color.g, color.b], separator: "")
        if diyActive {
            send(packet, label: "DOOD LED 1 \(name)", expect: "DOOD")
        } else {
            send(IdealProtocol.diyEnter(), label: "DEN 00 (entra in DIY, azzera la tela)", expect: nil)
            diyActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.send(packet, label: "DOOD LED 1 \(name)", expect: "DOOD")
            }
        }
    }

    func exitDIY(keepDrawing: Bool) {
        send(IdealProtocol.diyExit(keepDrawing: keepDrawing),
             label: keepDrawing ? "DSTOP 01 (esci, mantieni disegno)" : "DSTOP 00 (esci, ripristina)", expect: nil)
        diyActive = false
    }

    /// Invio di un blocco in chiaro su …9600, dopo la policy di sicurezza. Restituisce l'errore, se c'è.
    @discardableResult
    func send(_ plain: [UInt8], label: String, expect ackTag: String?) -> String? {
        let verdict = CommandSafety.evaluate(bytes: plain, role: .command, encoding: .plaintextEncryptInApp, ledCount: settings.ledCount)
        guard verdict.level != .blocked else {
            let reason = verdict.reasons.joined(separator: " ")
            log.add(.safety, IdealUUID.command, bytes: plain, "BLOCCATO \(label): \(reason)")
            lastResult = "Bloccato: \(reason)"
            return reason
        }
        guard let cipher = IdealCrypto.encrypt(plain) else { return "Cifratura fallita" }
        log.add(.event, IdealUUID.command, bytes: plain, "In chiaro \(label) [\(verdict.level.label)]")
        if let err = ble.write(cipher, to: IdealUUID.command, type: .withoutResponse, note: label) {
            lastResult = err
            log.add(.error, IdealUUID.command, err)
            return err
        }
        lastResult = "Inviato: \(label)"
        if let ackTag { waitAck(ackTag) }
        return nil
    }

    private func waitAck(_ tag: String) {
        pending = PendingAck(tag: tag, sentAt: Date())
        ackTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.pending, p.tag == tag else { return }
            self.pending = nil
            self.lastResult = "Nessuna risposta a \(tag) entro 2 s"
            self.log.add(.event, IdealUUID.notify, "Nessuna risposta a \(tag) entro 2 s")
        }
        ackTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Notifiche

    private func handleValue(_ uuid: String, _ bytes: [UInt8]) {
        guard CharacteristicRole.of(uuid) == .notify else { return }
        guard let reply = IdealReplyDecoder.decode(bytes) else {
            lastReply = "Notifica di \(bytes.count) byte non decifrabile come blocco AES"
            return
        }
        lastReply = reply.summary + " — " + Hex.string(reply.plain)
        switch reply.kind {
        case .version(let v):
            versions[lastVersionIndex] = v
            confirm("VE")
        case .ack(let tag):
            confirm(tag)
        case .frameAck(let tag, _):
            confirm(tag)
        case .text, .unrecognized:
            break
        }
    }

    private func confirm(_ tag: String) {
        if !sessionAcks.contains(tag) { sessionAcks.append(tag) }
        settings.addConfirmedTag(tag, for: deviceName)
        if pending?.tag == tag {
            let ms = Int(Date().timeIntervalSince(pending!.sentAt) * 1000)
            lastResult = "Risposta \(tag) in \(ms) ms"
            pending = nil
            ackTimeout?.cancel()
        }
    }

    private func resetSession() {
        versions = [:]
        sessionAcks = []
        diyActive = false
        pending = nil
        ackTimeout?.cancel()
    }

    // MARK: Diagnostica

    func diagnosticsReport() -> String {
        var lines: [String] = ["AUDI LIGHT STUDIO — diagnostica BLE", "Data: \(PacketLog.timestampFormatter.string(from: Date()))", ""]
        lines.append(ble.gattReport())
        lines.append("")
        lines.append("Modello (2901): \(modelString ?? "-")")
        for (k, v) in versions.sorted(by: { $0.key < $1.key }) { lines.append("VE \(k): \(v)") }
        lines.append("Ack in questa sessione: \(sessionAcks.joined(separator: ", "))")
        lines.append("Tag confermati su \(deviceName): \(confirmedTags.sorted().joined(separator: ", "))")
        lines.append("")
        lines.append("Verifica:")
        for c in checklist { lines.append("  [\(c.ok ? "x" : " ")] \(c.title) — \(c.detail)") }
        return lines.joined(separator: "\n")
    }
}
