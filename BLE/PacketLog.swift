import Foundation

/// Voce del log BLE con timestamp. Conservata in memoria ed esportabile.
struct PacketLogEntry: Identifiable, Equatable {
    enum Direction: String {
        case tx = "TX"       // scrittura verso il controller
        case rx = "RX"       // notifica / lettura dal controller
        case event = "EV"    // stato connessione, scoperta GATT
        case error = "ERR"
        case safety = "SAFE" // invio rifiutato dalla policy di sicurezza
    }

    let id = UUID()
    let date: Date
    let direction: Direction
    let characteristic: String?
    let bytes: [UInt8]
    let note: String

    static func == (a: PacketLogEntry, b: PacketLogEntry) -> Bool { a.id == b.id }

    var shortCharacteristic: String {
        guard let c = characteristic else { return "" }
        return c.count > 8 ? "…" + c.suffix(4) : c
    }

    func line(formatter: DateFormatter) -> String {
        var parts = [formatter.string(from: date), direction.rawValue]
        if let c = characteristic { parts.append(c) }
        if !bytes.isEmpty { parts.append("[\(bytes.count)] " + Hex.string(bytes)) }
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " | ")
    }
}

final class PacketLog: ObservableObject {
    @Published private(set) var entries: [PacketLogEntry] = []
    let maxEntries = 5000

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func add(_ direction: PacketLogEntry.Direction, _ characteristic: String? = nil, bytes: [UInt8] = [], _ note: String = "") {
        let entry = PacketLogEntry(date: Date(), direction: direction, characteristic: characteristic, bytes: bytes, note: note)
        let append = { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        if Thread.isMainThread { append() } else { DispatchQueue.main.async(execute: append) }
    }

    func clear() { entries.removeAll() }

    func text(header: String = "") -> String {
        let body = entries.map { $0.line(formatter: Self.timestampFormatter) }.joined(separator: "\n")
        return header.isEmpty ? body : header + "\n\n" + body
    }

    /// Scrive il log in Documents/Logs (visibile nell'app File) e restituisce l'URL.
    func export(header: String) throws -> URL {
        let dir = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "ble-log-" + Self.fileStamp() + ".txt"
        let url = dir.appendingPathComponent(name)
        try text(header: header).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func fileStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
