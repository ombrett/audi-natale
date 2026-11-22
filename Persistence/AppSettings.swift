import Foundation

/// Impostazioni persistenti (UserDefaults). Nessuna credenziale.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var targetName: String { didSet { defaults.set(targetName, forKey: Keys.targetName) } }
    @Published var showOnlyIdealDevices: Bool { didSet { defaults.set(showOnlyIdealDevices, forKey: Keys.showOnlyIdeal) } }
    @Published var autoReconnect: Bool { didSet { defaults.set(autoReconnect, forKey: Keys.autoReconnect) } }
    /// Dopo la connessione il controller riapplica il proprio stato (~1,5–2 s, idealLED): niente comandi prima.
    @Published var settleSeconds: Double { didSet { defaults.set(settleSeconds, forKey: Keys.settle) } }
    @Published var diyBrightness: Int { didSet { defaults.set(diyBrightness, forKey: Keys.diyBrightness) } }
    /// LED configurati sul controller collegato (limite di sicurezza: 400).
    @Published var ledCount: Int { didSet { defaults.set(ledCount, forKey: Keys.ledCount) } }
    @Published var lastPeripheralID: String? { didSet { defaults.set(lastPeripheralID, forKey: Keys.lastPeripheral) } }

    enum Keys {
        static let targetName = "targetName"
        static let showOnlyIdeal = "showOnlyIdeal"
        static let autoReconnect = "autoReconnect"
        static let settle = "settleSeconds"
        static let diyBrightness = "diyBrightness"
        static let ledCount = "ledCount"
        static let lastPeripheral = "lastPeripheralID"
        static let confirmedPrefix = "confirmedTags."
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        targetName = defaults.string(forKey: Keys.targetName) ?? IdealUUID.targetName
        showOnlyIdealDevices = defaults.object(forKey: Keys.showOnlyIdeal) as? Bool ?? true
        autoReconnect = defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true
        settleSeconds = defaults.object(forKey: Keys.settle) as? Double ?? 3
        diyBrightness = defaults.object(forKey: Keys.diyBrightness) as? Int ?? 50
        // Default 200: impianto verificato (2 file da 200 LED in parallelo a Y sulla stessa linea dati).
        let storedCount = defaults.object(forKey: Keys.ledCount) as? Int ?? 200
        ledCount = min(max(storedCount, 1), IdealProtocol.maxSafeLEDs)
        lastPeripheralID = defaults.string(forKey: Keys.lastPeripheral)
    }

    /// Tag a cui un controller specifico ha risposto con un ack ("…OK"): verificati sul dispositivo.
    func confirmedTags(for device: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Keys.confirmedPrefix + device) ?? [])
    }

    func addConfirmedTag(_ tag: String, for device: String) {
        var tags = confirmedTags(for: device)
        guard !tags.contains(tag) else { return }
        tags.insert(tag)
        defaults.set(Array(tags).sorted(), forKey: Keys.confirmedPrefix + device)
        objectWillChange.send()
    }

    func resetConfirmedTags(for device: String) {
        defaults.removeObject(forKey: Keys.confirmedPrefix + device)
        objectWillChange.send()
    }
}
