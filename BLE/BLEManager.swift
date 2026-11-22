import Foundation
import CoreBluetooth

/// Livello di trasporto CoreBluetooth: scansione, connessione, GATT, notifiche, scritture.
/// Non conosce il protocollo e NON scrive mai nulla automaticamente: ogni scrittura parte
/// da un'azione esplicita dell'utente. La coda delegate è la main queue.
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [UUID: DiscoveredDevice] = [:]
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var connectedID: UUID?
    @Published private(set) var connectedName: String?
    @Published private(set) var connectedAt: Date?
    @Published private(set) var services: [GATTServiceInfo] = []
    @Published private(set) var rssi: Int?
    @Published private(set) var maxWriteWithoutResponse: Int?
    @Published private(set) var maxWriteWithResponse: Int?
    @Published private(set) var queuedWrites = 0

    let log: PacketLog
    private let settings: AppSettings

    /// Valore ricevuto (notifica o lettura): uuid caratteristica, byte.
    var onValue: ((String, [UInt8]) -> Void)?
    var onDisconnect: (() -> Void)?
    var onReady: (() -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var current: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]   // chiave: UUID maiuscolo
    private var pendingServiceDiscoveries = 0
    private var userRequestedDisconnect = false
    private var connectTimeout: DispatchWorkItem?
    private var scanTimeout: DispatchWorkItem?
    private var rssiTimer: Timer?
    private var writeQueue: [(Data, CBCharacteristic, String)] = []

    init(log: PacketLog, settings: AppSettings) {
        self.log = log
        self.settings = settings
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    var sortedDevices: [DiscoveredDevice] {
        devices.values
            .filter { !settings.showOnlyIdealDevices || $0.isIdeal }
            .sorted { a, b in
                if a.isTarget(settings.targetName) != b.isTarget(settings.targetName) { return a.isTarget(settings.targetName) }
                return a.rssi > b.rssi
            }
    }

    var isSettled: Bool {
        guard phase == .ready, let at = connectedAt else { return false }
        return Date().timeIntervalSince(at) >= settings.settleSeconds
    }

    // MARK: Scansione

    func startScan(duration: TimeInterval = 20) {
        guard bluetoothState == .poweredOn else {
            log.add(.error, nil, "Scansione impossibile: \(bluetoothState.label)")
            return
        }
        devices.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        log.add(.event, nil, "Scansione avviata (\(Int(duration)) s)")
        scanTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopScan() }
        scanTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func stopScan() {
        scanTimeout?.cancel()
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
        log.add(.event, nil, "Scansione fermata: \(devices.count) dispositivi")
    }

    // MARK: Connessione

    func connect(_ id: UUID) {
        guard let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            log.add(.error, nil, "Periferica \(id) non trovata: avvia una scansione.")
            return
        }
        stopScan()
        if let cur = current, cur.identifier != id {
            userRequestedDisconnect = true
            central.cancelPeripheralConnection(cur)
        }
        peripherals[id] = p
        current = p
        p.delegate = self
        userRequestedDisconnect = false
        phase = .connecting
        connectedName = p.name ?? devices[id]?.name
        log.add(.event, nil, "Connessione a \(connectedName ?? id.uuidString)…")
        central.connect(p, options: nil)

        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .connecting, let p = self.current else { return }
            self.central.cancelPeripheralConnection(p)
            self.phase = .failed("timeout di connessione (15 s)")
            self.log.add(.error, nil, "Timeout di connessione")
        }
        connectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// Riconnessione all'ultima periferica usata (identificatore salvato).
    func reconnectLast() {
        guard let s = settings.lastPeripheralID, let id = UUID(uuidString: s) else {
            log.add(.error, nil, "Nessun dispositivo precedente salvato")
            return
        }
        connect(id)
    }

    func disconnect() {
        userRequestedDisconnect = true
        connectTimeout?.cancel()
        if let p = current {
            central.cancelPeripheralConnection(p)
        }
        if phase == .reconnecting || phase == .connecting {
            resetConnectionState()
            phase = .idle
        }
    }

    private func resetConnectionState() {
        rssiTimer?.invalidate()
        rssiTimer = nil
        services = []
        characteristics = [:]
        writeQueue = []
        queuedWrites = 0
        connectedAt = nil
        rssi = nil
        maxWriteWithResponse = nil
        maxWriteWithoutResponse = nil
        pendingServiceDiscoveries = 0
    }

    // MARK: GATT

    func characteristicInfo(_ uuid: String) -> GATTCharacteristicInfo? {
        let u = uuid.uppercased()
        for s in services { if let c = s.characteristics.first(where: { $0.uuid == u }) { return c } }
        return nil
    }

    func setNotify(_ on: Bool, for uuid: String) {
        guard let p = current, let c = characteristics[uuid.uppercased()] else { return }
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else {
            log.add(.error, uuid.uppercased(), "La caratteristica non supporta Notify/Indicate")
            return
        }
        log.add(.event, uuid.uppercased(), on ? "Richiesta sottoscrizione notifiche" : "Richiesta annullamento notifiche")
        p.setNotifyValue(on, for: c)
    }

    func read(_ uuid: String) {
        guard let p = current, let c = characteristics[uuid.uppercased()] else { return }
        guard c.properties.contains(.read) else {
            log.add(.error, uuid.uppercased(), "La caratteristica non supporta Read")
            return
        }
        p.readValue(for: c)
    }

    func readDescriptors(_ uuid: String) {
        guard let p = current, let c = characteristics[uuid.uppercased()] else { return }
        for d in c.descriptors ?? [] { p.readValue(for: d) }
    }

    /// Scrittura di basso livello. La policy di sicurezza va applicata PRIMA (IdealController / HEX editor);
    /// qui si ripete solo il controllo sulle caratteristiche vietate.
    @discardableResult
    func write(_ bytes: [UInt8], to uuid: String, type: CBCharacteristicWriteType, note: String) -> String? {
        let u = uuid.uppercased()
        guard CharacteristicRole.of(u).writable else {
            log.add(.safety, u, bytes: bytes, "Scrittura rifiutata: caratteristica non autorizzata")
            return "Caratteristica non autorizzata per la scrittura."
        }
        guard phase == .ready, let p = current, let c = characteristics[u] else {
            return "Non connesso o caratteristica assente."
        }
        if type == .withoutResponse && !c.properties.contains(.writeWithoutResponse) {
            return "La caratteristica non supporta Write Without Response."
        }
        if type == .withResponse && !c.properties.contains(.write) {
            return "La caratteristica non supporta Write con risposta."
        }
        let max = p.maximumWriteValueLength(for: type)
        if bytes.count > max {
            return "Pacchetto di \(bytes.count) byte oltre il massimo negoziato (\(max))."
        }
        let data = Data(bytes)
        if type == .withoutResponse && !p.canSendWriteWithoutResponse {
            writeQueue.append((data, c, note))
            queuedWrites = writeQueue.count
            log.add(.event, u, bytes: bytes, "In coda (buffer pieno): \(note)")
            return nil
        }
        p.writeValue(data, for: c, type: type)
        log.add(.tx, u, bytes: bytes, "\(type == .withResponse ? "W" : "WNR") \(note)")
        return nil
    }

    private func flushQueue() {
        guard let p = current else { return }
        while !writeQueue.isEmpty && p.canSendWriteWithoutResponse {
            let (data, c, note) = writeQueue.removeFirst()
            p.writeValue(data, for: c, type: .withoutResponse)
            log.add(.tx, c.uuid.uuidString.uppercased(), bytes: [UInt8](data), "WNR \(note)")
        }
        queuedWrites = writeQueue.count
    }

    private func rebuildServices() {
        guard let p = current else { services = []; return }
        services = (p.services ?? []).map { s -> GATTServiceInfo in
            let su = s.uuid.uuidString.uppercased()
            let chars = (s.characteristics ?? []).map { c -> GATTCharacteristicInfo in
                let cu = c.uuid.uuidString.uppercased()
                let old = services.first(where: { $0.uuid == su })?.characteristics.first(where: { $0.uuid == cu })
                let descs = (c.descriptors ?? []).map { d -> GATTDescriptorInfo in
                    let du = d.uuid.uuidString.uppercased()
                    let oldValue = old?.descriptors.first(where: { $0.uuid == du })?.value
                    return GATTDescriptorInfo(uuid: du, value: Self.describe(d.value) ?? oldValue)
                }
                return GATTCharacteristicInfo(serviceUUID: su, uuid: cu, propertiesRaw: c.properties.rawValue,
                                              isNotifying: c.isNotifying, descriptors: descs,
                                              lastValue: old?.lastValue, lastValueDate: old?.lastValueDate)
            }
            return GATTServiceInfo(uuid: su, characteristics: chars)
        }
    }

    private func updateLastValue(_ uuid: String, _ bytes: [UInt8]) {
        for si in services.indices {
            if let ci = services[si].characteristics.firstIndex(where: { $0.uuid == uuid }) {
                services[si].characteristics[ci].lastValue = bytes
                services[si].characteristics[ci].lastValueDate = Date()
            }
        }
    }

    static func describe(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let d as Data: return String(data: d, encoding: .utf8).map { $0.trimmingCharacters(in: .controlCharacters) } ?? Hex.string(d)
        case let n as NSNumber: return n.stringValue
        case nil: return nil
        default: return String(describing: value!)
        }
    }

    /// Testo con servizi, caratteristiche, proprietà e descrittori per la diagnostica.
    func gattReport() -> String {
        var lines: [String] = []
        lines.append("Dispositivo: \(connectedName ?? "-") (\(connectedID?.uuidString ?? "-"))")
        lines.append("RSSI: \(rssi.map { "\($0)" } ?? "-") dBm")
        lines.append("Max write without response: \(maxWriteWithoutResponse.map { "\($0)" } ?? "-") byte")
        lines.append("Max write with response: \(maxWriteWithResponse.map { "\($0)" } ?? "-") byte")
        for s in services {
            lines.append("Servizio \(s.uuid)")
            for c in s.characteristics {
                lines.append("  Caratteristica \(c.uuid) [\(c.propertyNames.joined(separator: ", "))] notify=\(c.isNotifying) ruolo=\(c.role.rawValue)")
                for d in c.descriptors {
                    lines.append("    Descrittore \(d.uuid) = \(d.value ?? "(non letto)")")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        log.add(.event, nil, central.state.label)
        if central.state != .poweredOn {
            isScanning = false
            if phase.isActive {
                resetConnectionState()
                phase = .failed(central.state.label)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        peripherals[id] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Senza nome"
        let rssiValue = RSSI.intValue
        let now = Date()
        if var d = devices[id] {
            // Aggiorna al massimo 2 volte al secondo per non saturare SwiftUI.
            guard now.timeIntervalSince(d.lastSeen) > 0.5 else { return }
            d.rssi = rssiValue == 127 ? d.rssi : rssiValue
            d.lastSeen = now
            if d.name == "Senza nome" { d.name = name }
            devices[id] = d
        } else {
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
            let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
            devices[id] = DiscoveredDevice(id: id, name: name, rssi: rssiValue, lastSeen: now,
                                           advertisedServices: services, isConnectable: connectable)
            if IdealUUID.isIdealName(name) {
                log.add(.event, nil, "Trovato \(name) RSSI \(rssiValue) dBm\(name == settings.targetName ? " ← controller atteso" : "")")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeout?.cancel()
        current = peripheral
        connectedID = peripheral.identifier
        connectedName = peripheral.name ?? connectedName
        connectedAt = Date()
        settings.lastPeripheralID = peripheral.identifier.uuidString
        phase = .discovering
        maxWriteWithoutResponse = peripheral.maximumWriteValueLength(for: .withoutResponse)
        maxWriteWithResponse = peripheral.maximumWriteValueLength(for: .withResponse)
        log.add(.event, nil, "Connesso a \(connectedName ?? "?"). Max WNR \(maxWriteWithoutResponse ?? 0) B, max W \(maxWriteWithResponse ?? 0) B. Nessuna scrittura automatica.")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.current?.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeout?.cancel()
        let msg = error?.localizedDescription ?? "connessione fallita"
        log.add(.error, nil, "Connessione fallita: \(msg)")
        resetConnectionState()
        phase = .failed(msg)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let wasUser = userRequestedDisconnect
        log.add(error == nil ? .event : .error, nil,
                "Disconnesso \(peripheral.name ?? "")\(error.map { ": \($0.localizedDescription)" } ?? "")\(wasUser ? " (richiesto)" : "")")
        // Disconnessione di una periferica precedente durante il passaggio a un'altra.
        guard peripheral.identifier == current?.identifier else { return }
        resetConnectionState()
        onDisconnect?()
        if !wasUser && settings.autoReconnect {
            phase = .reconnecting
            log.add(.event, nil, "Riconnessione automatica in attesa del dispositivo…")
            central.connect(peripheral, options: nil)   // richiesta pendente, nessun timeout
        } else {
            phase = .idle
            connectedID = nil
            current = nil
        }
        userRequestedDisconnect = false
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log.add(.error, nil, "Scoperta servizi: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            return
        }
        let list = peripheral.services ?? []
        pendingServiceDiscoveries = list.count
        log.add(.event, nil, "Servizi: " + list.map { $0.uuid.uuidString }.joined(separator: ", "))
        if list.isEmpty { phase = .ready; onReady?() }
        for s in list { peripheral.discoverCharacteristics(nil, for: s) }
        rebuildServices()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log.add(.error, service.uuid.uuidString, "Caratteristiche: \(error.localizedDescription)") }
        for c in service.characteristics ?? [] {
            characteristics[c.uuid.uuidString.uppercased()] = c
            peripheral.discoverDescriptors(for: c)
        }
        rebuildServices()
        pendingServiceDiscoveries -= 1
        if pendingServiceDiscoveries <= 0 && phase == .discovering {
            phase = .ready
            log.add(.event, nil, "GATT pronto: \(characteristics.count) caratteristiche")
            onReady?()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        for d in characteristic.descriptors ?? [] where d.uuid.uuidString.uppercased() == IdealUUID.userDescriptionDescriptor {
            // Lettura (non scrittura) del descrittore 2901: su …9600 contiene il modello, es. "TR2411R003-07".
            peripheral.readValue(for: d)
        }
        rebuildServices()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        let cu = descriptor.characteristic?.uuid.uuidString.uppercased()
        if let error {
            log.add(.error, cu, "Lettura descrittore \(descriptor.uuid.uuidString): \(error.localizedDescription)")
        } else {
            log.add(.rx, cu, "Descrittore \(descriptor.uuid.uuidString) = \(Self.describe(descriptor.value) ?? "nil")")
        }
        rebuildServices()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let u = characteristic.uuid.uuidString.uppercased()
        if let error {
            log.add(.error, u, "Valore: \(error.localizedDescription)")
            return
        }
        let bytes = [UInt8](characteristic.value ?? Data())
        var note = characteristic.isNotifying ? "notifica" : "lettura"
        if CharacteristicRole.of(u) == .notify, let reply = IdealReplyDecoder.decode(bytes) {
            note += " → AES: \(Hex.string(reply.plain)) → \(reply.summary)"
        }
        log.add(.rx, u, bytes: bytes, note)
        updateLastValue(u, bytes)
        onValue?(u, bytes)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let u = characteristic.uuid.uuidString.uppercased()
        if let error {
            log.add(.error, u, "Notifiche: \(error.localizedDescription)")
        } else {
            log.add(.event, u, characteristic.isNotifying ? "Notifiche attive" : "Notifiche disattivate")
        }
        rebuildServices()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let u = characteristic.uuid.uuidString.uppercased()
        if let error {
            log.add(.error, u, "Scrittura fallita: \(error.localizedDescription)")
        } else {
            log.add(.event, u, "Scrittura confermata dallo stack GATT")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushQueue()
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { rssi = RSSI.intValue }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        log.add(.event, nil, "Servizi modificati dal dispositivo: nuova scoperta")
        peripheral.discoverServices(nil)
    }
}
