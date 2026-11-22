import Foundation
import CoreBluetooth

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
    var advertisedServices: [String]
    var isConnectable: Bool?

    var isIdeal: Bool { IdealUUID.isIdealName(name) }
    func isTarget(_ targetName: String) -> Bool { name == targetName }
}

struct GATTDescriptorInfo: Identifiable, Equatable {
    var id: String { uuid }
    let uuid: String
    var value: String?
}

struct GATTCharacteristicInfo: Identifiable, Equatable {
    var id: String { serviceUUID + "/" + uuid }
    let serviceUUID: String
    let uuid: String
    let propertiesRaw: UInt
    var isNotifying: Bool
    var descriptors: [GATTDescriptorInfo]
    var lastValue: [UInt8]?
    var lastValueDate: Date?

    var properties: CBCharacteristicProperties { CBCharacteristicProperties(rawValue: propertiesRaw) }
    var role: CharacteristicRole { .of(uuid) }
    var canRead: Bool { properties.contains(.read) }
    var canWrite: Bool { properties.contains(.write) }
    var canWriteWithoutResponse: Bool { properties.contains(.writeWithoutResponse) }
    var canNotify: Bool { properties.contains(.notify) || properties.contains(.indicate) }

    var propertyNames: [String] {
        var n: [String] = []
        if properties.contains(.broadcast) { n.append("Broadcast") }
        if properties.contains(.read) { n.append("Read") }
        if properties.contains(.writeWithoutResponse) { n.append("Write Without Response") }
        if properties.contains(.write) { n.append("Write") }
        if properties.contains(.notify) { n.append("Notify") }
        if properties.contains(.indicate) { n.append("Indicate") }
        if properties.contains(.authenticatedSignedWrites) { n.append("Signed Write") }
        if properties.contains(.extendedProperties) { n.append("Extended") }
        return n
    }

    var displayName: String { uuid.count > 8 ? "…" + uuid.suffix(4) : uuid }
}

struct GATTServiceInfo: Identifiable, Equatable {
    var id: String { uuid }
    let uuid: String
    var characteristics: [GATTCharacteristicInfo]

    var label: String {
        switch IdealUUID.normalize(uuid) {
        case IdealUUID.controlService: return "Controllo iDeal (FFF0)"
        case IdealUUID.otaService: return "OTA JieLi (AE00)"
        case IdealUUID.unknownService: return "Sconosciuto (FD00)"
        default: return uuid
        }
    }
}

enum ConnectionPhase: Equatable {
    case idle
    case connecting
    case discovering
    case ready
    case reconnecting
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Non connesso"
        case .connecting: return "Connessione…"
        case .discovering: return "Scoperta servizi…"
        case .ready: return "Connesso"
        case .reconnecting: return "Riconnessione…"
        case .failed(let m): return "Errore: \(m)"
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .discovering, .ready, .reconnecting: return true
        default: return false
        }
    }
}

extension CBManagerState {
    var label: String {
        switch self {
        case .poweredOn: return "Bluetooth attivo"
        case .poweredOff: return "Bluetooth spento"
        case .unauthorized: return "Permesso Bluetooth negato"
        case .unsupported: return "Bluetooth LE non supportato"
        case .resetting: return "Bluetooth in reset"
        case .unknown: return "Stato Bluetooth sconosciuto"
        @unknown default: return "Stato Bluetooth non gestito"
        }
    }
}

extension CBCharacteristicWriteType {
    var label: String { self == .withResponse ? "Write (con risposta)" : "Write Without Response" }
}
