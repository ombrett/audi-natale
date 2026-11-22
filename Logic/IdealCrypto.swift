import Foundation
import CommonCrypto

/// AES-128-ECB senza padding usato dai controller iDeal LED / Winkison (ISP-*, IDL-*).
///
/// DOCUMENTATO: chiave pubblicata da 8none1/idealLED (estratta da libAES.so dell'app Android) e
/// riconfermata da KyleJamesWalker/glowmote su ISP-50542B. I vettori in Tests/main.swift
/// riproducono byte per byte le catture pubblicate.
/// DA VERIFICARE su ISP-B0717F: che il controller accetti la stessa chiave
/// (il Bluetooth Lab lo verifica con la risposta a "VE 00").
enum IdealCrypto {
    static let key: [UInt8] = [
        0x34, 0x52, 0x2A, 0x5B, 0x7A, 0x6E, 0x49, 0x2C,
        0x08, 0x09, 0x0A, 0x9D, 0x8D, 0x2A, 0x23, 0xF8,
    ]

    static let blockSize = 16

    /// Cifra uno o più blocchi da 16 byte. Restituisce nil se la lunghezza non è multipla di 16.
    static func encrypt(_ plain: [UInt8]) -> [UInt8]? {
        crypt(plain, operation: CCOperation(kCCEncrypt))
    }

    static func decrypt(_ cipher: [UInt8]) -> [UInt8]? {
        crypt(cipher, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ input: [UInt8], operation: CCOperation) -> [UInt8]? {
        guard !input.isEmpty, input.count % blockSize == 0 else { return nil }
        let keyBytes = key
        var output = [UInt8](repeating: 0, count: input.count + blockSize)
        let outputCapacity = output.count
        var moved = 0
        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            keyBytes, keyBytes.count,
            nil,
            input, input.count,
            &output, outputCapacity,
            &moved
        )
        guard status == CCCryptorStatus(kCCSuccess), moved == input.count else { return nil }
        return Array(output.prefix(moved))
    }
}
