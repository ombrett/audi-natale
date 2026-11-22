import Foundation
import CoreBluetooth
import Combine
import SwiftUI

/// Gestione di più centraline collegate contemporaneamente (almeno 4).
/// Ha un proprio CBCentralManager, separato da quello diagnostico del Bluetooth Lab.
final class ControllerHub: NSObject, ObservableObject {
    @Published private(set) var controllers: [ControllerConfig] = []
    @Published private(set) var links: [UUID: ControllerLink] = [:]
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var found: [UUID: DiscoveredDevice] = [:]   // chiave: identificatore CoreBluetooth
    @Published var autoReconnect = true

    let log: PacketLog
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var manualDisconnect: Set<UUID> = []
    private var linkObservers: [UUID: AnyCancellable] = [:]
    private let storeURL: URL

    static let palette = [0, 1, 2, 3, 4, 5]

    init(log: PacketLog) {
        self.log = log
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        storeURL = dir.appendingPathComponent("controllers.json")
        super.init()
        if let data = try? Data(contentsOf: storeURL), let list = try? JSONDecoder().decode([ControllerConfig].self, from: data) {
            controllers = list.sorted { $0.order < $1.order }
        }
        for c in controllers { makeLink(c) }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Configurazione

    var orderedLinks: [ControllerLink] { controllers.compactMap { links[$0.id] } }
    var readyLinks: [ControllerLink] { orderedLinks.filter { $0.isReady && $0.config.enabled } }
    var enabledControllers: [ControllerConfig] { controllers.filter { $0.enabled } }
    var allReady: Bool { !enabledControllers.isEmpty && enabledControllers.allSatisfy { links[$0.id]?.isReady == true } }
    var codebook: Codebook { Codebook(controllers: controllers) }
    var totalLEDs: Int { enabledControllers.reduce(0) { $0 + min($1.ledCount, IdealProtocol.maxSafeLEDs) } }

    func config(_ id: UUID) -> ControllerConfig? { controllers.first { $0.id == id } }

    func name(of id: UUID) -> String { config(id)?.name ?? "?" }

    @discardableResult
    func add(device: DiscoveredDevice, ledCount: Int = 200) -> ControllerConfig? {
        guard !controllers.contains(where: { $0.peripheralID == device.id || $0.bleName == device.name }) else { return nil }
        let n = controllers.count
        let c = ControllerConfig(name: "Centralina \(n + 1)", bleName: device.name, peripheralID: device.id,
                                 ledCount: min(ledCount, IdealProtocol.maxSafeLEDs), order: n, tint: n % 6)
        controllers.append(c)
        makeLink(c)
        persist()
        return c
    }

    /// Centralina prevista da un layout di progetto ma non ancora associata a un dispositivo reale.
    /// Non si collega a nulla finché non viene associata (nessuna scansione per nome vuoto).
    @discardableResult
    func addPlaceholder(name: String, ledCount: Int, copies: Int) -> ControllerConfig {
        let n = controllers.count
        let c = ControllerConfig(name: name, bleName: "", peripheralID: nil,
                                 ledCount: min(max(ledCount, 1), IdealProtocol.maxSafeLEDs), order: n,
                                 copiesPerPixel: min(max(copies, 1), 4), tint: n % 6)
        controllers.append(c)
        makeLink(c)
        persist()
        return c
    }

    var placeholders: [ControllerConfig] { controllers.filter { $0.isPlaceholder } }

    /// Associa un dispositivo trovato a una centralina già configurata (es. segnaposto del layout).
    func bind(_ id: UUID, to device: DiscoveredDevice) {
        guard var c = config(id), !controllers.contains(where: { $0.id != id && ($0.peripheralID == device.id || $0.bleName == device.name) }) else { return }
        disconnect(id)
        c.bleName = device.name
        c.peripheralID = device.id
        update(c)
    }

    func update(_ c: ControllerConfig) {
        guard let i = controllers.firstIndex(where: { $0.id == c.id }) else { return }
        var v = c
        v.ledCount = min(max(v.ledCount, 1), IdealProtocol.maxSafeLEDs)
        v.copiesPerPixel = min(max(v.copiesPerPixel, 1), 4)
        controllers[i] = v
        links[c.id]?.config = v
        persist()
    }

    func remove(_ id: UUID) {
        disconnect(id)
        controllers.removeAll { $0.id == id }
        for i in controllers.indices { controllers[i].order = i }
        links[id] = nil
        linkObservers[id] = nil
        persist()
    }

    func move(from: IndexSet, to: Int) {
        controllers.move(fromOffsets: from, toOffset: to)
        for i in controllers.indices { controllers[i].order = i; links[controllers[i].id]?.config.order = i }
        persist()
    }

    private func makeLink(_ c: ControllerConfig) {
        let link = ControllerLink(config: c, log: log)
        links[c.id] = link
        // Ripubblica i cambiamenti del link perché le viste che osservano l'hub si aggiornino.
        linkObservers[c.id] = link.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(controllers) { try? data.write(to: storeURL, options: .atomic) }
    }

    // MARK: Scansione

    func startScan() {
        guard bluetoothState == .poweredOn else { return }
        found = [:]
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.stopScan() }
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    // MARK: Connessione

    func connectAll() {
        for c in enabledControllers { connect(c.id) }
    }

    func connect(_ id: UUID) {
        guard let link = links[id], let c = config(id), bluetoothState == .poweredOn else { return }
        if link.isReady || link.state.isBusy { return }
        if c.isPlaceholder {
            link.didFail("Da associare: aggiungi la centralina reale e associala a \"\(c.name)\"")
            return
        }
        manualDisconnect.remove(id)
        var p: CBPeripheral?
        if let pid = c.peripheralID { p = peripherals[pid] ?? central.retrievePeripherals(withIdentifiers: [pid]).first }
        if p == nil, let match = found.values.first(where: { $0.name == c.bleName }) { p = peripherals[match.id] }
        guard let peripheral = p else {
            // Identificatore sconosciuto: cerca per nome.
            link.willConnect()
            startScan()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak link] in
                guard let self, let link, link.state == .connecting, link.peripheral == nil else { return }
                if let m = self.found.values.first(where: { $0.name == c.bleName }), let per = self.peripherals[m.id] {
                    self.open(per, for: id)
                } else {
                    link.didFail("\(c.bleName) non trovata")
                }
            }
            return
        }
        open(peripheral, for: id)
    }

    private func open(_ p: CBPeripheral, for id: UUID) {
        guard let link = links[id] else { return }
        peripherals[p.identifier] = p
        if var c = config(id), c.peripheralID != p.identifier {
            c.peripheralID = p.identifier
            update(c)
        }
        link.peripheral = p
        link.willConnect()
        central.connect(p, options: nil)
    }

    func disconnect(_ id: UUID) {
        guard let link = links[id] else { return }
        manualDisconnect.insert(id)
        link.cancelTransfer()
        if let p = link.peripheral { central.cancelPeripheralConnection(p) } else { link.didDisconnect(error: nil, willReconnect: false) }
    }

    func disconnectAll() { for c in controllers { disconnect(c.id) } }

    private func link(for p: CBPeripheral) -> ControllerLink? {
        orderedLinks.first { $0.peripheral?.identifier == p.identifier || $0.config.peripheralID == p.identifier }
    }

    // MARK: Invio coordinato

    /// Invia a ogni centralina pronta il suo disegno; gli invii procedono in parallelo.
    func apply(_ targets: [UUID: [RGB]], mode: DIYMode = .static, speed: Int = 100, brightness: Int, window: Int) {
        for link in readyLinks {
            guard let t = targets[link.id] else { continue }
            link.brightness = brightness
            link.sendWindow = window
            link.apply(target: t, mode: mode, speed: speed)
        }
    }

    /// Chiama `completion` quando tutte le centraline pronte hanno terminato un invio iniziato dopo `since`.
    func whenIdle(since: Date, timeout: TimeInterval = 40, completion: @escaping (String?) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let links = self.readyLinks
            if links.isEmpty { timer.invalidate(); completion("Nessuna centralina pronta"); return }
            var allDone = true
            for l in links {
                guard let t = l.transfer, t.startedAt >= since else { allDone = false; continue }
                if let e = t.error { timer.invalidate(); completion("\(l.config.name): \(e)"); return }
                if t.finishedAt == nil { allDone = false }
            }
            if allDone { timer.invalidate(); completion(nil) }
            else if Date() > deadline { timer.invalidate(); completion("Invio non completato entro \(Int(timeout)) s") }
        }
    }

    func cancelAll() { for l in orderedLinks { l.cancelTransfer() } }
}

extension ControllerHub: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state != .poweredOn {
            for l in orderedLinks where l.state != .offline { l.didDisconnect(error: nil, willReconnect: false) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard IdealUUID.isIdealName(name) else { return }
        peripherals[peripheral.identifier] = peripheral
        found[peripheral.identifier] = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, lastSeen: Date(),
                                                        advertisedServices: [], isConnectable: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        link(for: peripheral)?.didConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        link(for: peripheral)?.didFail(error?.localizedDescription ?? "Connessione fallita")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let link = link(for: peripheral) else { return }
        let reconnect = autoReconnect && !manualDisconnect.contains(link.id) && link.config.enabled
        link.didDisconnect(error: error, willReconnect: reconnect)
        if reconnect {
            link.willConnect()
            central.connect(peripheral, options: nil)   // richiesta pendente: si ricollega quando torna in portata
        }
    }
}
