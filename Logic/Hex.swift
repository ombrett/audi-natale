import Foundation

/// Conversione e validazione HEX. Nessuna dipendenza da UIKit/CoreBluetooth: compilata anche nei test.
enum Hex {
    enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case invalidCharacter(Character)
        case oddLength(Int)

        var description: String {
            switch self {
            case .empty: return "Nessun byte inserito."
            case .invalidCharacter(let c): return "Carattere non esadecimale: '\(c)'."
            case .oddLength(let n): return "Numero dispari di cifre (\(n)): ogni byte richiede 2 cifre."
            }
        }
    }

    /// Accetta "0d 44 4F", "0x0d,0x44", "0D:44:4F" o "0d444f".
    static func parse(_ text: String) -> Result<[UInt8], ParseError> {
        var cleaned = text.replacingOccurrences(of: "0x", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "0X", with: " ")
        var digits: [Character] = []
        for ch in cleaned {
            if ch == " " || ch == "," || ch == ":" || ch == "-" || ch == "\n" || ch == "\t" || ch == "\r" {
                continue
            }
            guard ch.isHexDigit else { return .failure(.invalidCharacter(ch)) }
            digits.append(ch)
        }
        if digits.isEmpty { return .failure(.empty) }
        if digits.count % 2 != 0 { return .failure(.oddLength(digits.count)) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var i = 0
        while i < digits.count {
            let pair = String([digits[i], digits[i + 1]])
            guard let value = UInt8(pair, radix: 16) else { return .failure(.invalidCharacter(digits[i])) }
            bytes.append(value)
            i += 2
        }
        return .success(bytes)
    }

    static func string(_ bytes: [UInt8], separator: String = " ") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    static func string(_ data: Data, separator: String = " ") -> String {
        string([UInt8](data), separator: separator)
    }

    /// Caratteri ASCII stampabili, '.' per gli altri.
    static func ascii(_ bytes: [UInt8]) -> String {
        String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}
