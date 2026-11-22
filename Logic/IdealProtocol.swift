import Foundation

// MARK: - UUID

/// Caratteristiche GATT del controller. Confronto sempre in maiuscolo (CBUUID.uuidString).
enum IdealUUID {
    static let controlService = "FFF0"
    /// DOCUMENTATO: comandi cifrati AES, 16 byte, Write Without Response (glowmote, idealLED).
    static let command = "D44BC439-ABFD-45A2-B575-925416129600"
    /// DOCUMENTATO: notifiche cifrate (ack "<TAG>OK", risposte VE).
    static let notify = "D44BC439-ABFD-45A2-B575-925416129601"
    /// DOCUMENTATO: frame bulk in chiaro dopo MULT / DOOT (fino a 100 byte con MTU alta).
    static let bulk = "D44BC439-ABFD-45A2-B575-92541612960A"
    /// DOCUMENTATO (solo glowmote): livelli musica cifrati "02 effetto livello".
    static let rhythm = "D44BC439-ABFD-45A2-B575-92541612960B"

    /// Servizio OTA JieLi (RCSP). MAI scrivere.
    static let otaService = "AE00"
    static let otaWrite = "AE01"
    static let otaNotify = "AE02"
    /// Servizio sconosciuto. MAI scrivere.
    static let unknownService = "FD00"
    static let unknownWrite = "FD01"
    static let unknownWriteNotify = "FD02"

    static let userDescriptionDescriptor = "2901"

    static let targetName = "ISP-B0717F"
    static let namePrefixes = ["ISP-", "IDL-"]

    static func isIdealName(_ name: String?) -> Bool {
        guard let name else { return false }
        return namePrefixes.contains { name.hasPrefix($0) }
    }
}

/// Ruolo noto di una caratteristica: decide quali scritture sono permesse.
enum CharacteristicRole: String, CaseIterable {
    case command, notify, bulk, rhythm, otaWrite, otaNotify, unknownWrite, unknownWriteNotify, other

    static func of(_ uuid: String) -> CharacteristicRole {
        switch uuid.uppercased() {
        case IdealUUID.command: return .command
        case IdealUUID.notify: return .notify
        case IdealUUID.bulk: return .bulk
        case IdealUUID.rhythm: return .rhythm
        case IdealUUID.otaWrite: return .otaWrite
        case IdealUUID.otaNotify: return .otaNotify
        case IdealUUID.unknownWrite: return .unknownWrite
        case IdealUUID.unknownWriteNotify: return .unknownWriteNotify
        default: return .other
        }
    }

    var label: String {
        switch self {
        case .command: return "Comandi (AES) — documentata"
        case .notify: return "Notifiche ack (AES) — documentata"
        case .bulk: return "Frame bulk in chiaro — documentata"
        case .rhythm: return "Livelli musica (AES) — documentata solo da glowmote"
        case .otaWrite: return "OTA JieLi — scrittura vietata"
        case .otaNotify: return "OTA JieLi — notifiche"
        case .unknownWrite, .unknownWriteNotify: return "Non identificata — scrittura vietata"
        case .other: return "Non identificata — scrittura vietata"
        }
    }

    /// Le uniche caratteristiche su cui l'app accetta scritture manuali.
    var writable: Bool {
        switch self {
        case .command, .bulk, .rhythm: return true
        default: return false
        }
    }
}

// MARK: - Pacchetti

struct RGB: Equatable, Codable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    static let red = RGB(r: 0xFF, g: 0, b: 0)
    static let green = RGB(r: 0, g: 0xFF, b: 0)
    static let blue = RGB(r: 0, g: 0, b: 0xFF)
    static let black = RGB(r: 0, g: 0, b: 0)
}

enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case ledIndexOutOfRange(Int, max: Int)
    case valueOutOfRange(field: String, value: Int, range: ClosedRange<Int>)

    var description: String {
        switch self {
        case let .ledIndexOutOfRange(i, max):
            return "Indice LED \(i) oltre il limite di sicurezza (\(max)): il firmware documentato non controlla i limiti."
        case let .valueOutOfRange(field, value, range):
            return "\(field) = \(value) fuori dall'intervallo sicuro \(range.lowerBound)…\(range.upperBound)."
        }
    }
}

/// Encoder dei comandi documentati per la famiglia ISP (firmware TR22xx/TR23xx/TR24xx).
/// Ogni comando è un blocco in chiaro da 16 byte: `<len> <TAG ASCII> <argomenti> <zeri>`.
enum IdealProtocol {
    /// Buffer pixel del firmware TR2309R002-02 analizzato da glowmote: 400 LED.
    /// DOOD scrive senza controllo dei limiti oltre questo valore → corruzione RAM persistente.
    /// Finché il firmware 23.09.12.1 non sarà analizzato, l'app non supera questo limite.
    static let maxSafeLEDs = 400

    static func tagged(_ tag: String, _ args: [UInt8], length: UInt8? = nil) -> [UInt8] {
        let tagBytes = Array(tag.utf8)
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = length ?? UInt8(tagBytes.count + args.count)
        for (i, b) in tagBytes.enumerated() { p[1 + i] = b }
        for (i, b) in args.enumerated() { p[1 + tagBytes.count + i] = b }
        return p
    }

    /// `05 'TURN' 00|01` — catturato (8none1, glowmote).
    static func power(_ on: Bool) -> [UInt8] { tagged("TURN", [on ? 1 : 0]) }

    /// `03 'VE' 00|01` — catturato; il controller risponde con una stringa "V…".
    static func versionQuery(second: Bool) -> [UInt8] { tagged("VE", [second ? 1 : 0]) }

    /// `04 'DEN' 00` — entra in DIY: secondo il firmware TR2309 salva e AZZERA la tela.
    static func diyEnter() -> [UInt8] { tagged("DEN", [0]) }

    /// `05 'DSTOP' 01` mantiene il disegno, `00` ripristina la modalità precedente.
    static func diyExit(keepDrawing: Bool) -> [UInt8] { tagged("DSTOP", [keepDrawing ? 1 : 0], length: 5) }

    /// `0d 'DOOD' 01 <idx BE> 02 64 R G B <luminosità>` — un pixel, modalità statica, velocità 100.
    static func diyPixel(index: Int, color: RGB, brightness: Int) throws -> [UInt8] {
        guard index >= 0, index < maxSafeLEDs else {
            throw ProtocolError.ledIndexOutOfRange(index, max: maxSafeLEDs - 1)
        }
        guard (0...100).contains(brightness) else {
            throw ProtocolError.valueOutOfRange(field: "Luminosità DIY", value: brightness, range: 0...100)
        }
        return dood(target: 1, index: UInt16(index), color: color, brightness: UInt8(brightness))
    }

    /// `0d 'DOOD' 00 <conteggio BE> …` — riempie tutti i LED (conteggio = numero LED).
    static func diyFill(ledCount: Int, color: RGB, brightness: Int) throws -> [UInt8] {
        guard ledCount >= 1, ledCount <= maxSafeLEDs else {
            throw ProtocolError.ledIndexOutOfRange(ledCount, max: maxSafeLEDs)
        }
        guard (0...100).contains(brightness) else {
            throw ProtocolError.valueOutOfRange(field: "Luminosità DIY", value: brightness, range: 0...100)
        }
        return dood(target: 0, index: UInt16(ledCount), color: color, brightness: UInt8(brightness))
    }

    private static func dood(target: UInt8, index: UInt16, color: RGB, brightness: UInt8) -> [UInt8] {
        let hi = UInt8(index >> 8), lo = UInt8(index & 0xFF)
        return tagged("DOOD", [target, hi, lo, 0x02, 0x64, color.r, color.g, color.b, brightness], length: 0x0D)
    }

    static func encrypted(_ plain: [UInt8]) -> [UInt8]? { IdealCrypto.encrypt(plain) }
}

// MARK: - Decodifica

/// Tag ASCII conosciuti (dall'app vendor, dal firmware TR2309 e dalle catture).
enum IdealTag {
    static let all: [String] = [
        "TURN", "SGLS", "MULT", "DOOD", "DOOT", "DOOTCP", "DTARTCY", "DEN", "DSTOP", "VE", "TIME",
        "CT", "SCHD", "MIC", "RSTOPR", "LAMPT", "LAMPN", "LAMPQ", "DIRECT", "SPLAY", "SPLACP",
        "STARTCY", "MOVE", "CHECKLINE", "CONFIRM", "CSTOPR", "LIGHT", "TEST", "SPEED",
    ]

    /// Tag più lungo che prefissa il testo (es. "DOOTCP" prima di "DOOT").
    static func match(_ text: String) -> String? {
        all.filter { text.hasPrefix($0) }.max { $0.count < $1.count }
    }
}

struct DecodedPlaintext: Equatable {
    let plain: [UInt8]
    /// Byte 0 del blocco.
    let length: Int
    /// Testo ASCII iniziale (lettere maiuscole) dopo il byte di lunghezza.
    let asciiRun: String
    let tag: String?

    init(plain: [UInt8]) {
        self.plain = plain
        self.length = plain.first.map { Int($0) } ?? 0
        var run = ""
        for b in plain.dropFirst() {
            if (0x41...0x5A).contains(b) { run.append(Character(UnicodeScalar(b))) } else { break }
        }
        self.asciiRun = run
        self.tag = IdealTag.match(run)
    }

    /// Byte dopo il tag.
    var arguments: [UInt8] {
        guard let tag else { return [] }
        return Array(plain.dropFirst(1 + tag.count))
    }
}

struct DecodedReply: Equatable {
    enum Kind: Equatable {
        case ack(tag: String)            // "<TAG>OK"
        case frameAck(tag: String, frame: Int) // "DOOTREOK n", "MULTREOK"
        case version(String)             // "V024.11.03.7"
        case text(String)
        case unrecognized
    }
    let cipher: [UInt8]
    let plain: [UInt8]
    let kind: Kind

    var summary: String {
        switch kind {
        case .ack(let t): return "ACK \(t)OK"
        case .frameAck(let t, let f): return "ACK frame \(t) #\(f)"
        case .version(let v): return "Versione \(v)"
        case .text(let s): return "Testo \"\(s)\""
        case .unrecognized: return "Non riconosciuto"
        }
    }
}

enum IdealReplyDecoder {
    /// Decifra una notifica da …9601. Solo i primi len+1 byte sono significativi (glowmote).
    static func decode(_ cipher: [UInt8]) -> DecodedReply? {
        guard cipher.count == 16, let plain = IdealCrypto.decrypt(cipher) else { return nil }
        return DecodedReply(cipher: cipher, plain: plain, kind: classify(plain))
    }

    static func classify(_ plain: [UInt8]) -> DecodedReply.Kind {
        guard let first = plain.first else { return .unrecognized }
        let len = Int(first)
        guard len >= 1, len <= 15 else { return .unrecognized }
        let body = Array(plain[1...len])
        // DOOTREOK / SPLAREOK: l'indice del frame sostituisce lo zero finale.
        if let last = body.last, body.count >= 3 {
            let head = String(bytes: body.dropLast(), encoding: .ascii) ?? ""
            if head.hasSuffix("REOK"), isUpperASCII(Array(body.dropLast())) {
                return .frameAck(tag: String(head.dropLast(4)), frame: Int(last))
            }
        }
        let printable = body.filter { $0 != 0 }
        guard !printable.isEmpty, printable.allSatisfy({ (0x20...0x7E).contains($0) }),
              let text = String(bytes: printable, encoding: .ascii) else {
            return .unrecognized
        }
        if text.hasPrefix("V"), text.dropFirst().first?.isNumber == true {
            return .version(text)
        }
        if text.hasSuffix("REOK") {
            return .frameAck(tag: String(text.dropLast(4)), frame: 0)
        }
        if text.hasSuffix("OK"), text.count > 2 {
            return .ack(tag: String(text.dropLast(2)))
        }
        return .text(text)
    }

    private static func isUpperASCII(_ bytes: [UInt8]) -> Bool {
        !bytes.isEmpty && bytes.allSatisfy { (0x41...0x5A).contains($0) }
    }
}
