import Foundation

/// Animazione di un pixel DIY (byte 8 di DOOD). Solo `.static` è stato catturato.
enum DIYMode: UInt8, CaseIterable, Identifiable, Codable {
    case flash = 0
    case breathe = 1
    case `static` = 2
    var id: UInt8 { rawValue }
    var label: String {
        switch self {
        case .flash: return "Lampeggio"
        case .breathe: return "Respiro"
        case .static: return "Fisso"
        }
    }
}

/// Effetti della centralina. Fonti: glowmote (catture su ISP-50542B e analisi del firmware TR2309).
enum IdealEffects {
    /// SGLS: 10 modalità a due colori (primo piano, sfondo). Catturate: 0 e 1.
    static let sglsNames = [
        "Colore fisso", "Barra su sfondo", "Accumulo", "Meteora", "Onda pulsante",
        "Inseguimento", "Punto in corsa", "Barra che entra ed esce", "Respiro a due colori", "Strobo a due colori",
    ]
    static let sglsCaptured: Set<Int> = [0, 1]

    /// MULT: 12 effetti multicolore. Catturati: 0, 1, 7, 8, 9.
    static let multNames = [
        "Bande che scorrono", "Scintillio", "Tendina colore", "Tendina dal centro", "Un punto per colore",
        "Mezza barra", "Accumulo a colori", "Meteore colorate", "Onde colorate", "Gradiente che scorre",
        "Salto di colore", "Respiro tra i colori",
    ]
    static let multCaptured: Set<Int> = [0, 1, 7, 8, 9]

    /// Con MTU 23 un frame su …960A può portare 18 byte di colore: 6 colori.
    static let maxSceneColors = 6
    static let sceneFrameLength = 20

    /// Scala un canale per la luminosità come l'app vendor: un canale acceso non scende sotto 2.
    static func scale(_ c: RGB, _ pct: Int) -> RGB {
        let p = UInt16(min(max(pct, 0), 100))
        func ch(_ v: UInt8) -> UInt8 { v == 0 ? 0 : max(UInt8(UInt16(v) * p / 100), 2) }
        return RGB(r: ch(c.r), g: ch(c.g), b: ch(c.b))
    }
}

extension IdealProtocol {
    /// `0F 'SGLS' modo inv 64 velocità R G B R G B 32` (glowmote `effect`).
    static func effect(mode: Int, reversed: Bool, speed: Int, foreground: RGB, background: RGB, brightness: Int) throws -> [UInt8] {
        guard (0...9).contains(mode) else { throw ProtocolError.valueOutOfRange(field: "Modalità SGLS", value: mode, range: 0...9) }
        guard (0...100).contains(speed) else { throw ProtocolError.valueOutOfRange(field: "Velocità", value: speed, range: 0...100) }
        guard (0...100).contains(brightness) else { throw ProtocolError.valueOutOfRange(field: "Luminosità", value: brightness, range: 0...100) }
        let a = IdealEffects.scale(foreground, brightness), b = IdealEffects.scale(background, brightness)
        return tagged("SGLS", [UInt8(mode), reversed ? 1 : 0, 0x64, UInt8(speed), a.r, a.g, a.b, b.r, b.g, b.b, 0x32])
    }

    /// Scena multicolore: intestazione `0A 'MULT' effetto inv 64 velocità n luminosità` (cifrata, su …9600)
    /// e frame in chiaro su …960A `<3n+1> 00 R G B …` lungo 20 byte.
    static func scene(effect: Int, reversed: Bool, speed: Int, colors: [RGB], brightness: Int) throws -> (header: [UInt8], frame: [UInt8]) {
        guard (0...11).contains(effect) else { throw ProtocolError.valueOutOfRange(field: "Effetto MULT", value: effect, range: 0...11) }
        guard (1...IdealEffects.maxSceneColors).contains(colors.count) else {
            throw ProtocolError.valueOutOfRange(field: "Numero colori", value: colors.count, range: 1...IdealEffects.maxSceneColors)
        }
        guard (0...100).contains(speed) else { throw ProtocolError.valueOutOfRange(field: "Velocità", value: speed, range: 0...100) }
        guard (0...100).contains(brightness) else { throw ProtocolError.valueOutOfRange(field: "Luminosità", value: brightness, range: 0...100) }
        let header = tagged("MULT", [UInt8(effect), reversed ? 1 : 0, 0x64, UInt8(speed), UInt8(colors.count), UInt8(brightness)])
        var frame = [UInt8](repeating: 0, count: IdealEffects.sceneFrameLength)
        frame[0] = UInt8(colors.count * 3 + 1)
        let p = UInt16(brightness)
        for (i, c) in colors.enumerated() {
            frame[2 + i * 3] = UInt8(UInt16(c.r) * p / 100)
            frame[3 + i * 3] = UInt8(UInt16(c.g) * p / 100)
            frame[4 + i * 3] = UInt8(UInt16(c.b) * p / 100)
        }
        return (header, frame)
    }
}
