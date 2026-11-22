import Foundation

/// Classificazione di un pacchetto prima dell'invio.
enum SafetyLevel: Int, Comparable {
    /// Byte identici a una cattura pubblicata dell'app vendor (8none1/idealLED, glowmote).
    /// Non ancora provati su ISP-B0717F finché il controller non risponde con l'ack.
    case documented = 0
    /// Tag noto ma byte mai catturati, oppure frame bulk: richiede conferma esplicita.
    case experimental = 1
    /// Vietato: OTA, caratteristiche non identificate, tag sconosciuti, valori fuori limite.
    case blocked = 2

    static func < (a: SafetyLevel, b: SafetyLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .documented: return "Documentato"
        case .experimental: return "Sperimentale"
        case .blocked: return "Bloccato"
        }
    }
}

struct SafetyVerdict: Equatable {
    let level: SafetyLevel
    let reasons: [String]
    /// Blocco in chiaro (solo per caratteristiche cifrate), utile per il log.
    let plaintext: [UInt8]?
    let tag: String?
}

/// Come interpretare i byte digitati nell'editor HEX per …9600 / …960B.
enum PayloadEncoding: String, CaseIterable, Identifiable {
    /// L'utente digita il blocco in chiaro, l'app lo cifra.
    case plaintextEncryptInApp
    /// L'utente digita già il testo cifrato (es. copiato da una cattura).
    case alreadyEncrypted
    var id: String { rawValue }
    var label: String {
        switch self {
        case .plaintextEncryptInApp: return "In chiaro → cifra AES"
        case .alreadyEncrypted: return "Già cifrato"
        }
    }
}

enum CommandSafety {
    /// Tag documentati da catture byte-exact (vendor app su controller ISP).
    static let capturedTags: Set<String> = ["TURN", "SGLS", "MULT", "DOOD", "DOOT", "DOOTCP", "DTARTCY", "DEN", "DSTOP", "VE", "SCHD", "MIC", "RSTOPR"]

    /// Tag vietati: modificano configurazione persistente o sono test di fabbrica.
    /// LAMPT/LAMPN/CT: tipo LED e numero LED (oltre 400 corrompe la RAM su TR2309);
    /// SPLAY: playlist con indici non controllati che scrivono in flash; TEST: test di fabbrica;
    /// CHECKLINE/CONFIRM/CSTOPR: wizard ordine canali, salvato in flash.
    static let blockedTags: Set<String> = ["LAMPT", "LAMPN", "CT", "SPLAY", "SPLACP", "STARTCY", "TEST", "CHECKLINE", "CONFIRM", "CSTOPR"]

    /// Valuta una scrittura su una caratteristica. `bytes` sono quelli digitati.
    static func evaluate(bytes: [UInt8], role: CharacteristicRole, encoding: PayloadEncoding, ledCount: Int) -> SafetyVerdict {
        switch role {
        case .otaWrite:
            return SafetyVerdict(level: .blocked, reasons: ["AE01 è il canale OTA JieLi: nessuna scrittura consentita."], plaintext: nil, tag: nil)
        case .unknownWrite, .unknownWriteNotify, .other, .notify, .otaNotify:
            return SafetyVerdict(level: .blocked, reasons: ["Caratteristica non identificata o non destinata ai comandi: scrittura vietata."], plaintext: nil, tag: nil)
        case .bulk:
            return evaluateBulk(bytes)
        case .command:
            return evaluateCommand(bytes, encoding: encoding, ledCount: ledCount)
        case .rhythm:
            return evaluateRhythm(bytes, encoding: encoding)
        }
    }

    private static func plaintext(_ bytes: [UInt8], encoding: PayloadEncoding) -> [UInt8]? {
        guard bytes.count == 16 else { return nil }
        switch encoding {
        case .plaintextEncryptInApp: return bytes
        case .alreadyEncrypted: return IdealCrypto.decrypt(bytes)
        }
    }

    static func evaluateCommand(_ bytes: [UInt8], encoding: PayloadEncoding, ledCount: Int) -> SafetyVerdict {
        guard bytes.count == 16 else {
            return SafetyVerdict(level: .blocked, reasons: ["I comandi su …9600 sono un singolo blocco AES da 16 byte (inseriti: \(bytes.count))."], plaintext: nil, tag: nil)
        }
        guard let plain = plaintext(bytes, encoding: encoding) else {
            return SafetyVerdict(level: .blocked, reasons: ["Impossibile decifrare il blocco."], plaintext: nil, tag: nil)
        }
        let decoded = DecodedPlaintext(plain: plain)
        guard let tag = decoded.tag else {
            return SafetyVerdict(level: .blocked, reasons: ["Tag sconosciuto (\"\(decoded.asciiRun)\"): non si inviano comandi inventati."], plaintext: plain, tag: nil)
        }
        if blockedTags.contains(tag) {
            return SafetyVerdict(level: .blocked, reasons: ["\(tag) modifica configurazione persistente o è un test di fabbrica: vietato."], plaintext: plain, tag: tag)
        }
        let args = decoded.arguments
        func arg(_ i: Int) -> Int { i < args.count ? Int(args[i]) : 0 }
        var reasons: [String] = []
        var level: SafetyLevel = capturedTags.contains(tag) ? .documented : .experimental
        if level == .experimental { reasons.append("\(tag) compare nell'app/firmware ma non è mai stato catturato.") }

        switch tag {
        case "TURN":
            if arg(0) > 1 { return blocked(plain, tag, "TURN accetta solo 00 o 01.") }
        case "VE":
            if arg(0) > 1 { return blocked(plain, tag, "VE accetta solo 00 o 01.") }
        case "DEN":
            if arg(0) != 0 { level = .experimental; reasons.append("Solo DEN 00 è stato catturato.") }
        case "DSTOP":
            if arg(0) > 1 { return blocked(plain, tag, "DSTOP accetta solo 00 o 01.") }
        case "SGLS":
            if arg(0) > 9 { return blocked(plain, tag, "SGLS: modalità \(arg(0)) > 9 scrive fuori array nel firmware.") }
            if arg(0) > 1 { level = max(level, .experimental); reasons.append("SGLS modalità \(arg(0)): ricavata dal firmware, mai catturata.") }
        case "MULT":
            if arg(0) > 11 { return blocked(plain, tag, "MULT: effetto \(arg(0)) > 11 scrive fuori array.") }
            if !(1...7).contains(arg(4)) { return blocked(plain, tag, "MULT: numero colori \(arg(4)) fuori da 1…7.") }
            level = max(level, .experimental); reasons.append("MULT richiede poi i frame colore su …960A.")
        case "DOOD":
            let target = arg(0)
            let index = (arg(1) << 8) | arg(2)
            let mode = arg(3), speed = arg(4), brightness = arg(8)
            if target > 1 { return blocked(plain, tag, "DOOD: target \(target) non valido (00 riempi, 01 pixel).") }
            if target == 1 && index >= min(ledCount, IdealProtocol.maxSafeLEDs) {
                return blocked(plain, tag, "DOOD: indice \(index) ≥ limite \(min(ledCount, IdealProtocol.maxSafeLEDs)).")
            }
            if target == 0 && (index < 1 || index > min(ledCount, IdealProtocol.maxSafeLEDs)) {
                return blocked(plain, tag, "DOOD riempi: conteggio \(index) fuori da 1…\(min(ledCount, IdealProtocol.maxSafeLEDs)).")
            }
            if mode > 2 { return blocked(plain, tag, "DOOD: modalità \(mode) > 2.") }
            if !(1...100).contains(speed) { return blocked(plain, tag, "DOOD: velocità \(speed) fuori da 1…100.") }
            if brightness > 100 { return blocked(plain, tag, "DOOD: luminosità \(brightness) > 100.") }
            if mode != 2 { level = max(level, .experimental); reasons.append("Solo la modalità 02 (statica) è stata catturata.") }
        case "DOOT":
            level = max(level, .experimental); reasons.append("DOOT avvia un trasferimento bulk: il totale LED dei frame non deve superare il numero di LED.")
        default:
            break
        }
        if level == .documented { reasons.append("Formato identico alle catture pubblicate; non ancora confermato su questo controller.") }
        return SafetyVerdict(level: level, reasons: reasons, plaintext: plain, tag: tag)
    }

    static func evaluateRhythm(_ bytes: [UInt8], encoding: PayloadEncoding) -> SafetyVerdict {
        guard let plain = plaintext(bytes, encoding: encoding) else {
            return SafetyVerdict(level: .blocked, reasons: ["…960B accetta un blocco AES da 16 byte."], plaintext: nil, tag: nil)
        }
        guard plain[0] == 0x02, plain[1] <= 9, (1...100).contains(Int(plain[2])), plain[3...].allSatisfy({ $0 == 0 }) else {
            return SafetyVerdict(level: .blocked, reasons: ["Formato atteso: 02 <effetto 0…9> <livello 1…100> + zeri."], plaintext: plain, tag: nil)
        }
        return SafetyVerdict(level: .experimental, reasons: ["Documentato solo da glowmote; non necessario per questo progetto."], plaintext: plain, tag: "RHYTHM")
    }

    static func evaluateBulk(_ bytes: [UInt8]) -> SafetyVerdict {
        guard bytes.count >= 2, bytes.count <= 100 else {
            return SafetyVerdict(level: .blocked, reasons: ["I frame bulk sono 2…100 byte."], plaintext: nil, tag: nil)
        }
        return SafetyVerdict(level: .experimental, reasons: [
            "Frame bulk in chiaro: valido solo dopo MULT/DOOT. Un upload interrotto sposta l'offset di scrittura del firmware.",
        ], plaintext: nil, tag: "BULK")
    }

    private static func blocked(_ plain: [UInt8], _ tag: String, _ reason: String) -> SafetyVerdict {
        SafetyVerdict(level: .blocked, reasons: [reason], plaintext: plain, tag: tag)
    }
}
