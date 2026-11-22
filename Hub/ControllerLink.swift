import Foundation
import CoreBluetooth

/// Avanzamento di un invio DOOD su una centralina.
struct LinkTransfer: Equatable {
    var total: Int
    var done: Int
    var startedAt: Date
    var retries: Int
    var finishedAt: Date?
    var error: String?

    var opsPerSecond: Double? {
        let t = (finishedAt ?? Date()).timeIntervalSince(startedAt)
        return t > 0 && done > 0 ? Double(done) / t : nil
    }
    var isRunning: Bool { finishedAt == nil && error == nil }
}

/// Connessione e protocollo di UNA centralina. Il trasporto (CoreBluetooth) e il protocollo
/// (IdealProtocol, solo comandi verificati o confermati esplicitamente) restano separati:
/// questa classe usa gli encoder di Logic/ e non costruisce byte da sé.
final class ControllerLink: NSObject, ObservableObject, Identifiable {
    enum State: Equatable {
        case offline, connecting, discovering, settling, subscribing, verifying, ready
        case failed(String)

        var label: String {
            switch self {
            case .offline: return "Non collegata"
            case .connecting: return "Connessione…"
            case .discovering: return "Lettura servizi…"
            case .settling: return "Assestamento…"
            case .subscribing: return "Notifiche…"
            case .verifying: return "Verifica protocollo…"
            case .ready: return "Pronta"
            case .failed(let m): return m
            }
        }
        var isBusy: Bool {
            switch self {
            case .connecting, .discovering, .settling, .subscribing, .verifying: return true
            default: return false
            }
        }
    }

    let id: UUID
    @Published var config: ControllerConfig
    @Published private(set) var state: State = .offline
    @Published private(set) var versions: [String] = []
    @Published private(set) var model: String?
    @Published private(set) var rssi: Int?
    @Published private(set) var transfer: LinkTransfer?
    @Published private(set) var canvas: [RGB]?
    @Published private(set) var lastRate: Double?
    @Published private(set) var lastMessage: String?

    var peripheral: CBPeripheral?
    let log: PacketLog
    var settleSeconds: Double = 3
    var sendWindow = 6
    var brightness = 50

    private var chars: [String: CBCharacteristic] = [:]
    private var writeQueue: [(Data, CBCharacteristic)] = []
    private var stateTimer: DispatchWorkItem?
    private var rssiTimer: Timer?
    private var diyActive = false
    private var diyMode: DIYMode = .static
    private var diySpeed = 100
    private var canvasAnimation: (DIYMode, Int) = (.static, 100)
    private var opQueue: [PixelOp] = []
    private var batch: [PixelOp] = []
    private var batchAcks = 0
    private var batchRetried = false
    private var opTimeout: DispatchWorkItem?
    private var queuedTarget: [RGB]?
    private var waiters: [(tag: String, deadline: DispatchWorkItem, completion: (Bool) -> Void)] = []

    init(config: ControllerConfig, log: PacketLog) {
        self.id = config.id
        self.config = config
        self.log = log
        super.init()
    }

    var isReady: Bool { state == .ready }

    private func note(_ dir: PacketLogEntry.Direction, _ uuid: String? = nil, bytes: [UInt8] = [], _ text: String) {
        log.add(dir, uuid, bytes: bytes, "[\(config.name)] \(text)")
    }

    // MARK: Ciclo di connessione (chiamato dall'hub)

    func willConnect() {
        state = .connecting
        lastMessage = nil
    }

    func didConnect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .discovering
        chars = [:]
        writeQueue = []
        diyActive = false
        canvas = nil
        note(.event, nil, "Connessa")
        p.discoverServices([CBUUID(string: IdealUUID.controlService)])
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.peripheral?.readRSSI() }
    }

    func didDisconnect(error: Error?, willReconnect: Bool) {
        rssiTimer?.invalidate()
        stateTimer?.cancel()
        opTimeout?.cancel()
        if transfer?.isRunning == true { transfer?.error = "Centralina disconnessa" }
        opQueue = []; batch = []; queuedTarget = nil
        for w in waiters { w.deadline.cancel(); w.completion(false) }
        waiters = []
        diyActive = false
        canvas = nil
        state = willReconnect ? .connecting : .offline
        if let error { note(.error, nil, "Disconnessa: \(error.localizedDescription)") } else { note(.event, nil, "Disconnessa") }
    }

    func didFail(_ message: String) {
        state = .failed(message)
        note(.error, nil, message)
    }

    private func afterSettle() {
        state = .settling
        stateTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.subscribe() }
        stateTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds, execute: work)
    }

    private func subscribe() {
        guard let p = peripheral, let n = chars[IdealUUID.notify] else { didFail("Caratteristica notifiche assente"); return }
        state = .subscribing
        p.setNotifyValue(true, for: n)
        timeout(4) { [weak self] in
            guard let self, self.state == .subscribing else { return }
            self.didFail("Notifiche non attivate")
        }
    }

    private func verify() {
        state = .verifying
        versions = []
        send(IdealProtocol.versionQuery(second: false), label: "VE 00")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.send(IdealProtocol.versionQuery(second: true), label: "VE 01")
        }
        timeout(4) { [weak self] in
            guard let self, self.state == .verifying else { return }
            self.didFail(self.versions.isEmpty ? "Nessuna risposta VE: protocollo non confermato" : "Risposta VE incompleta")
        }
    }

    private func timeout(_ seconds: Double, _ body: @escaping () -> Void) {
        stateTimer?.cancel()
        let work = DispatchWorkItem(block: body)
        stateTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Invio

    /// Blocco in chiaro su …9600 dopo la policy di sicurezza.
    @discardableResult
    func send(_ plain: [UInt8], label: String) -> String? {
        let verdict = CommandSafety.evaluate(bytes: plain, role: .command, encoding: .plaintextEncryptInApp, ledCount: config.ledCount)
        guard verdict.level != .blocked else {
            let reason = verdict.reasons.joined(separator: " ")
            note(.safety, IdealUUID.command, bytes: plain, "BLOCCATO \(label): \(reason)")
            return reason
        }
        guard let cipher = IdealCrypto.encrypt(plain) else { return "Cifratura fallita" }
        return write(cipher, to: IdealUUID.command, label: label)
    }

    @discardableResult
    func write(_ bytes: [UInt8], to uuid: String, label: String) -> String? {
        guard CharacteristicRole.of(uuid).writable else { return "Caratteristica non autorizzata" }
        guard let p = peripheral, let c = chars[uuid.uppercased()] else { return "Non collegata" }
        guard bytes.count <= p.maximumWriteValueLength(for: .withoutResponse) else { return "Pacchetto oltre l'MTU" }
        let data = Data(bytes)
        if p.canSendWriteWithoutResponse && writeQueue.isEmpty {
            p.writeValue(data, for: c, type: .withoutResponse)
        } else {
            writeQueue.append((data, c))
        }
        note(.tx, uuid, bytes: bytes, label)
        return nil
    }

    private func flush() {
        guard let p = peripheral else { return }
        while !writeQueue.isEmpty && p.canSendWriteWithoutResponse {
            let (d, c) = writeQueue.removeFirst()
            p.writeValue(d, for: c, type: .withoutResponse)
        }
    }

    // MARK: Disegno (DOOD verificato, a finestra)

    func apply(target: [RGB], mode: DIYMode = .static, speed: Int = 100) {
        guard isReady else { return }
        let n = min(config.ledCount, IdealProtocol.maxSafeLEDs)
        let t = Array(target.prefix(n)) + [RGB](repeating: .black, count: max(0, n - target.count))
        diyMode = mode
        diySpeed = min(max(speed, 1), 100)
        if transfer?.isRunning == true { queuedTarget = t; return }
        if !diyActive {
            send(IdealProtocol.diyEnter(), label: "DEN 00")
            diyActive = true
            canvas = [RGB](repeating: .black, count: n)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.start(t) }
        } else {
            start(t)
        }
    }

    func cancelTransfer() {
        opQueue = []; batch = []; queuedTarget = nil
        opTimeout?.cancel()
        if transfer?.isRunning == true { transfer?.error = "Annullato"; canvas = nil }
    }

    private func start(_ target: [RGB]) {
        if canvasAnimation != (diyMode, diySpeed) { canvas = nil }
        canvasAnimation = (diyMode, diySpeed)
        let current = canvas?.count == target.count ? canvas : nil
        let ops = PixelPlanner.plan(current: current, target: target)
        if ops.isEmpty {
            transfer = LinkTransfer(total: 0, done: 0, startedAt: Date(), retries: 0, finishedAt: Date(), error: nil)
            finished()
            return
        }
        if current == nil { canvas = [RGB](repeating: .black, count: target.count) }
        opQueue = ops
        transfer = LinkTransfer(total: ops.count, done: 0, startedAt: Date(), retries: 0, finishedAt: nil, error: nil)
        nextBatch()
    }

    private func packet(_ op: PixelOp) throws -> [UInt8] {
        let b = min(max(brightness, 0), 100)
        switch op {
        case .fill(let c):
            return try IdealProtocol.diyFill(ledCount: canvas?.count ?? config.ledCount, color: c, brightness: b, mode: diyMode.rawValue, speed: diySpeed)
        case .pixel(let i, let c):
            return try IdealProtocol.diyPixel(index: i, color: c, brightness: b, mode: diyMode.rawValue, speed: diySpeed)
        }
    }

    private func nextBatch() {
        guard !opQueue.isEmpty else { finished(); return }
        let n = min(max(sendWindow, 1), 8, opQueue.count)
        batch = Array(opQueue.prefix(n))
        opQueue.removeFirst(n)
        batchRetried = false
        transmitBatch()
    }

    private func transmitBatch() {
        batchAcks = 0
        for op in batch {
            do {
                if let err = send(try packet(op), label: "DOOD") { fail(err); return }
            } catch { fail("\(error)"); return }
        }
        opTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.batchTimedOut() }
        opTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + 0.15 * Double(batch.count), execute: work)
    }

    private func ackDOOD() {
        guard !batch.isEmpty else { return }
        batchAcks += 1
        guard batchAcks >= batch.count else { return }
        opTimeout?.cancel()
        if var c = canvas { for op in batch { PixelPlanner.apply(op, to: &c) }; canvas = c }
        transfer?.done += batch.count
        batch = []
        nextBatch()
    }

    private func batchTimedOut() {
        guard !batch.isEmpty else { return }
        if !batchRetried {
            batchRetried = true
            transfer?.retries += 1
            transmitBatch()
        } else {
            fail("Conferme DOODOK mancanti (\(batchAcks)/\(batch.count))")
        }
    }

    private func fail(_ reason: String) {
        opTimeout?.cancel()
        opQueue = []; batch = []; canvas = nil
        transfer?.error = reason
        lastMessage = reason
        note(.error, nil, "Invio interrotto: \(reason)")
    }

    private func finished() {
        transfer?.finishedAt = Date()
        if let t = transfer {
            if let r = t.opsPerSecond { lastRate = r }
            if t.retries > 0 { canvas = nil }
        }
        if let next = queuedTarget {
            queuedTarget = nil
            start(next)
        }
    }

    // MARK: Effetti nativi

    private func waitFor(_ tag: String, timeout: TimeInterval = 2, completion: @escaping (Bool) -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let i = self.waiters.firstIndex(where: { $0.tag == tag }) else { return }
            self.waiters.remove(at: i).completion(false)
        }
        waiters.append((tag, work, completion))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func leaveDIY(then: @escaping () -> Void) {
        guard diyActive else { then(); return }
        cancelTransfer()
        send(IdealProtocol.diyExit(keepDrawing: false), label: "DSTOP 00")
        diyActive = false
        canvas = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: then)
    }

    func playEffect(mode: Int, reversed: Bool, speed: Int, foreground: RGB, background: RGB, brightness: Int, completion: @escaping (Bool) -> Void) {
        guard isReady, let packet = try? IdealProtocol.effect(mode: mode, reversed: reversed, speed: speed,
                                                              foreground: foreground, background: background, brightness: brightness) else {
            completion(false); return
        }
        leaveDIY { [weak self] in
            guard let self else { return }
            if self.send(packet, label: "SGLS \(mode)") != nil { completion(false); return }
            self.waitFor("SGLS", completion: completion)
        }
    }

    func playScene(effect: Int, reversed: Bool, speed: Int, colors: [RGB], brightness: Int, completion: @escaping (Bool) -> Void) {
        guard isReady, let scene = try? IdealProtocol.scene(effect: effect, reversed: reversed, speed: speed, colors: colors, brightness: brightness) else {
            completion(false); return
        }
        leaveDIY { [weak self] in
            guard let self else { return }
            if self.send(scene.header, label: "MULT \(effect)") != nil { completion(false); return }
            self.waitFor("MULT") { ok in
                guard ok, self.write(scene.frame, to: IdealUUID.bulk, label: "MULT colori") == nil else { completion(false); return }
                self.waitFor("MULTCP", timeout: 3, completion: completion)
            }
        }
    }

    func power(_ on: Bool) {
        send(IdealProtocol.power(on), label: on ? "TURN 01" : "TURN 00")
    }

    // MARK: Notifiche

    private func handle(_ bytes: [UInt8]) {
        guard let reply = IdealReplyDecoder.decode(bytes) else { return }
        note(.rx, IdealUUID.notify, bytes: bytes, reply.summary)
        let tag: String?
        switch reply.kind {
        case .version(let v):
            if !versions.contains(v) { versions.append(v) }
            if state == .verifying && !versions.isEmpty {
                stateTimer?.cancel()
                state = .ready
                note(.event, nil, "Pronta: \(versions.joined(separator: " · "))")
            }
            tag = "VE"
        case .ack(let t): tag = t
        case .frameAck(let t, _): tag = t
        default: tag = nil
        }
        guard let tag else { return }
        if tag == "DOOD" { ackDOOD() }
        if let i = waiters.firstIndex(where: { $0.tag == tag }) {
            let w = waiters.remove(at: i)
            w.deadline.cancel()
            w.completion(true)
        }
    }
}

extension ControllerLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let s = peripheral.services?.first(where: { $0.uuid.uuidString.uppercased() == IdealUUID.controlService }) else {
            didFail("Servizio FFF0 assente: non è una centralina compatibile")
            return
        }
        peripheral.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] { chars[c.uuid.uuidString.uppercased()] = c }
        guard chars[IdealUUID.command] != nil, chars[IdealUUID.notify] != nil else {
            didFail("Caratteristiche …9600/…9601 assenti")
            return
        }
        if let c = chars[IdealUUID.command] { peripheral.discoverDescriptors(for: c) }
        afterSettle()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        for d in characteristic.descriptors ?? [] where d.uuid.uuidString.uppercased() == IdealUUID.userDescriptionDescriptor {
            peripheral.readValue(for: d)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        model = BLEManager.describe(descriptor.value)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid.uuidString.uppercased() == IdealUUID.notify else { return }
        if characteristic.isNotifying && state == .subscribing {
            stateTimer?.cancel()
            verify()
        } else if let error {
            didFail("Notifiche: \(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid.uuidString.uppercased() == IdealUUID.notify else { return }
        handle([UInt8](characteristic.value ?? Data()))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flush()
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { rssi = RSSI.intValue }
    }
}
