import Foundation
import simd

// Test della logica di protocollo, eseguiti su macOS in GitHub Actions:
//   swiftc -O -o logictests Logic/*.swift Tests/main.swift && ./logictests
// I testi cifrati attesi provengono da catture pubblicate dell'app vendor:
//   8none1/idealLED att_protocol.md, KyleJamesWalker/glowmote docs/protocols/ideal-led.md

var failures = 0
var passed = 0

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name) \(detail())")
    }
}

func hex(_ s: String) -> [UInt8] {
    switch Hex.parse(s) {
    case .success(let b): return b
    case .failure(let e): fatalError("hex non valido nel test: \(e)")
    }
}

// MARK: Hex
check(Hex.parse("0d 44 4F") == .success([0x0D, 0x44, 0x4F]), "hex con spazi")
check(Hex.parse("0x0d,0x44") == .success([0x0D, 0x44]), "hex con 0x e virgole")
check(Hex.parse("0D:44") == .success([0x0D, 0x44]), "hex con due punti")
check(Hex.parse("abc") == .failure(.oddLength(3)), "hex lunghezza dispari")
check(Hex.parse("zz") == .failure(.invalidCharacter("z")), "hex carattere non valido")
check(Hex.parse("  ") == .failure(.empty), "hex vuoto")
check(Hex.string([0x0A, 0xFF]) == "0A FF", "hex to string")

// MARK: AES — vettori da catture pubblicate
let vectors: [(String, [UInt8], String)] = [
    ("TURN 00 (off)", IdealProtocol.power(false), "79d1dba40919c246a8580ae7d11b7884"),
    ("TURN 01 (on)", IdealProtocol.power(true), "84dd5042374150897ac82f39110968a8"),
    ("VE 00", IdealProtocol.versionQuery(second: false), "263a91cc5f1bf003ce437b733478ada2"),
    ("VE 01", IdealProtocol.versionQuery(second: true), "d12e61ad95a00bd3c56bee6f9cb545fe"),
    ("DEN 00", IdealProtocol.diyEnter(), "cbe9305dbde55cf3f8f13873f0920f2f"),
    ("DSTOP 01", IdealProtocol.diyExit(keepDrawing: true), "5eb9c3c21f0457240f0c39e0d0953039"),
    ("DSTOP 00", IdealProtocol.diyExit(keepDrawing: false), "5724de0f03efb16acbe078544cbc4ce1"),
    ("DOOD pixel 0 a51515 b65", try! IdealProtocol.diyPixel(index: 0, color: RGB(r: 0xA5, g: 0x15, b: 0x15), brightness: 65), "89875e93862614aca7f70d38702bff7b"),
    ("DOOD pixel 179 a50000 b50", try! IdealProtocol.diyPixel(index: 179, color: RGB(r: 0xA5, g: 0, b: 0), brightness: 50), "746a837fe5d1e12408d9e11f34df95a2"),
    ("DOOD fill 180 56a542 b50", try! IdealProtocol.diyFill(ledCount: 180, color: RGB(r: 0x56, g: 0xA5, b: 0x42), brightness: 50), "dcdd7fe7cbf6235242153c019b839bb9"),
]
for (name, plain, expected) in vectors {
    let cipher = IdealCrypto.encrypt(plain) ?? []
    check(Hex.string(cipher, separator: "").lowercased() == expected, "AES \(name)", "ottenuto \(Hex.string(cipher, separator: ""))")
    check(IdealCrypto.decrypt(hex(expected)) == plain, "AES decrypt \(name)")
}

// Colore rosso dalla cattura 8none1 (SGLS): decifra e verifica l'intestazione.
let sglsRed = IdealCrypto.decrypt(hex("2dec317e7181ccb079fc665ae43fa9dd")) ?? []
check(sglsRed == hex("0F 53 47 4C 53 00 00 64 50 1F 00 00 1F 00 00 32"), "decrypt SGLS rosso 8none1")

// MARK: Packet layout
check(IdealProtocol.diyExit(keepDrawing: true)[0] == 5, "DSTOP lunghezza 5")
check(try! IdealProtocol.diyPixel(index: 0, color: .red, brightness: 100) == hex("0d 44 4f 4f 44 01 00 00 02 64 ff 00 00 64 00 00"), "DOOD pixel 0 rosso")
check(try! IdealProtocol.diyPixel(index: 0, color: .blue, brightness: 100) == hex("0d 44 4f 4f 44 01 00 00 02 64 00 00 ff 64 00 00"), "DOOD pixel 0 blu")
check(try! IdealProtocol.diyPixel(index: 300, color: .red, brightness: 50)[6...7] == [0x01, 0x2C], "DOOD indice big-endian")
check((try? IdealProtocol.diyPixel(index: 400, color: .red, brightness: 50)) == nil, "DOOD indice 400 rifiutato")
check((try? IdealProtocol.diyPixel(index: 1599, color: .red, brightness: 50)) == nil, "DOOD indice 1599 rifiutato")
check((try? IdealProtocol.diyPixel(index: 0, color: .red, brightness: 101)) == nil, "DOOD luminosità 101 rifiutata")
check((try? IdealProtocol.diyFill(ledCount: 401, color: .red, brightness: 50)) == nil, "DOOD fill 401 rifiutato")

// MARK: Decodifica risposte
func plainReply(_ s: String) -> [UInt8] {
    var p = Array(s.utf8)
    p.insert(UInt8(p.count), at: 0)
    while p.count < 16 { p.append(0) }
    return p
}
check(IdealReplyDecoder.classify(plainReply("TURNOK")) == .ack(tag: "TURN"), "ack TURNOK")
check(IdealReplyDecoder.classify(hex("06 54 55 52 4E 4F 4B 00 06 53 47 4C 53 4F 4B 00")) == .ack(tag: "TURN"), "ack TURNOK con coda della tabella")
check(IdealReplyDecoder.classify(plainReply("DOODOK")) == .ack(tag: "DOOD"), "ack DOODOK")
check(IdealReplyDecoder.classify(plainReply("V024.11.03.7")) == .version("V024.11.03.7"), "versione")
var dootre = plainReply("DOOTREOK"); dootre[0] = 9; dootre[9] = 2
check(IdealReplyDecoder.classify(dootre) == .frameAck(tag: "DOOT", frame: 2), "ack frame DOOTREOK 2")
check(IdealReplyDecoder.classify([UInt8](repeating: 0xEE, count: 16)) == .unrecognized, "risposta non riconosciuta")
let encAck = IdealCrypto.encrypt(plainReply("DOODOK"))!
check(IdealReplyDecoder.decode(encAck)?.kind == .ack(tag: "DOOD"), "decode notifica cifrata")

// MARK: Tag
check(DecodedPlaintext(plain: hex("06 44 4F 4F 54 43 50 00 00 00 00 00 00 00 00 00")).tag == "DOOTCP", "tag più lungo DOOTCP")
check(DecodedPlaintext(plain: IdealProtocol.diyEnter()).tag == "DEN", "tag DEN")

// MARK: Sicurezza
func level(_ b: [UInt8], _ role: CharacteristicRole, _ enc: PayloadEncoding = .plaintextEncryptInApp, leds: Int = 400) -> SafetyLevel {
    CommandSafety.evaluate(bytes: b, role: role, encoding: enc, ledCount: leds).level
}
check(level(IdealProtocol.power(true), .command) == .documented, "TURN documentato")
check(level(hex("84dd5042374150897ac82f39110968a8"), .command, .alreadyEncrypted) == .documented, "TURN già cifrato documentato")
check(level(try! IdealProtocol.diyPixel(index: 0, color: .red, brightness: 50), .command) == .documented, "DOOD pixel 0 documentato")
check(level(try! IdealProtocol.diyPixel(index: 10, color: .red, brightness: 50), .command, leds: 5) == .blocked, "DOOD oltre numero LED bloccato")
check(level(hex("0d 44 4f 4f 44 01 06 40 02 64 ff 00 00 64 00 00"), .command) == .blocked, "DOOD indice 1600 bloccato")
check(level(hex("0d 44 4f 4f 44 01 00 00 02 00 ff 00 00 64 00 00"), .command) == .blocked, "DOOD velocità 0 bloccata")
check(level(hex("0d 44 4f 4f 44 01 00 00 01 64 ff 00 00 64 00 00"), .command) == .experimental, "DOOD modalità 1 sperimentale")
check(level(hex("09 4C 41 4D 50 4E 06 40 06 40 00 00 00 00 00 00"), .command) == .blocked, "LAMPN bloccato")
check(level(hex("05 54 45 53 54 00 00 00 00 00 00 00 00 00 00 00"), .command) == .blocked, "TEST bloccato")
check(level(hex("0e 43 54 01 01 00 00 64 00 64 00 00 00 00 00 00"), .command) == .blocked, "CT bloccato")
check(level(hex("05 41 42 43 44 00 00 00 00 00 00 00 00 00 00 00"), .command) == .blocked, "tag sconosciuto bloccato")
check(level(hex("0F 53 47 4C 53 0A 00 64 50 1F 00 00 1F 00 00 32"), .command) == .blocked, "SGLS modalità 10 bloccata")
check(level(hex("0F 53 47 4C 53 00 00 64 50 1F 00 00 1F 00 00 32"), .command) == .documented, "SGLS modalità 0 documentata")
check(level(hex("04 4D 4F 56 45 00 00 00 00 00 00 00 00 00 00 00"), .command) == .experimental, "MOVE sperimentale")
check(level(Array(IdealProtocol.power(true).dropLast()), .command) == .blocked, "comando da 15 byte bloccato")
check(level(IdealProtocol.power(true), .otaWrite) == .blocked, "AE01 bloccata")
check(level(IdealProtocol.power(true), .unknownWrite) == .blocked, "FD01 bloccata")
check(level(IdealProtocol.power(true), .unknownWriteNotify) == .blocked, "FD02 bloccata")
check(level(hex("02 00 32 00 00 00 00 00 00 00 00 00 00 00 00 00"), .rhythm) == .experimental, "960B livello sperimentale")
check(level(hex("02 0A 32 00 00 00 00 00 00 00 00 00 00 00 00 00"), .rhythm) == .blocked, "960B effetto 10 bloccato")
check(level([0x07, 0x00, 0xFF], .bulk) == .experimental, "bulk sperimentale")
check(level([UInt8](repeating: 0, count: 101), .bulk) == .blocked, "bulk 101 byte bloccato")

// MARK: Pianificatore pixel
let black200 = [RGB](repeating: .black, count: 200)
var oneRed = black200; oneRed[0] = .red
check(PixelPlanner.plan(current: black200, target: oneRed) == [.pixel(0, .red)], "plan: un pixel cambiato")
check(PixelPlanner.plan(current: oneRed, target: oneRed).isEmpty, "plan: nessun cambiamento")
check(PixelPlanner.plan(current: nil, target: oneRed) == [.fill(.black), .pixel(0, .red)], "plan: stato sconosciuto riempie")
var mostlyBlue = [RGB](repeating: .blue, count: 200); mostlyBlue[5] = .red
check(PixelPlanner.plan(current: black200, target: mostlyBlue) == [.fill(.blue), .pixel(5, .red)], "plan: riempi + eccezioni")
var state = black200
for op in PixelPlanner.plan(current: black200, target: mostlyBlue) { PixelPlanner.apply(op, to: &state) }
check(state == mostlyBlue, "plan: applicato produce il target")
var alt = black200
for i in stride(from: 0, to: 200, by: 2) { alt[i] = .red }
let altPlan = PixelPlanner.plan(current: black200, target: alt)
check(altPlan.count == 100, "plan: alternato 100 operazioni", "\(altPlan.count)")
var s2 = black200
for op in altPlan { PixelPlanner.apply(op, to: &s2) }
check(s2 == alt, "plan: alternato corretto")
check(PixelPlanner.mostFrequent([.red, .blue, .blue]) == .blue, "colore più frequente")

// MARK: Effetti (vettori glowmote, catture su ISP-50542B)
func cipherHex(_ p: [UInt8]) -> String { Hex.string(IdealCrypto.encrypt(p) ?? [], separator: "").lowercased() }
let sglsRedEffect = try! IdealProtocol.effect(mode: 0, reversed: false, speed: 0x50, foreground: .red, background: .red, brightness: 100)
check(cipherHex(sglsRedEffect) == "73baa3e311ef375b0c2965911e7f5357", "SGLS rosso = cattura")
let sglsGreen = try! IdealProtocol.effect(mode: 0, reversed: false, speed: 0x50, foreground: .green, background: .green, brightness: 100)
check(cipherHex(sglsGreen) == "a06566adefd31c59d5c85979620ce9ef", "SGLS verde = cattura")
let sglsBlue = try! IdealProtocol.effect(mode: 0, reversed: false, speed: 0x50, foreground: .blue, background: .blue, brightness: 100)
check(cipherHex(sglsBlue) == "c7f95a08c3583941208cca2d3e6e91c0", "SGLS blu = cattura")
check((try? IdealProtocol.effect(mode: 10, reversed: false, speed: 50, foreground: .red, background: .blue, brightness: 50)) == nil, "SGLS modalità 10 rifiutata")
check(IdealEffects.scale(.red, 0) == RGB(r: 2, g: 0, b: 0), "scala: canale acceso minimo 2")
let magenta = RGB(r: 0xFF, g: 0, b: 0xFF), violet = RGB(r: 0x14, g: 0, b: 0xCB)
let sc1 = try! IdealProtocol.scene(effect: 7, reversed: false, speed: 5, colors: [magenta, violet], brightness: 0x1D)
check(cipherHex(sc1.header) == "612074c06b15b5b0616f2569e669062c", "MULT velocità 5 luminosità 29 = cattura")
check(Array(sc1.frame.prefix(8)) == hex("07 00 49 00 49 05 00 3a") && sc1.frame.count == 20, "MULT frame colori = cattura, 20 byte")
let sc2 = try! IdealProtocol.scene(effect: 7, reversed: false, speed: 100, colors: [magenta, violet], brightness: 100)
check(cipherHex(sc2.header) == "29d3a784888e6dcd9baaccee9809a18c", "MULT velocità 100 = cattura")
let sc3 = try! IdealProtocol.scene(effect: 7, reversed: true, speed: 100, colors: [magenta, violet], brightness: 100)
check(cipherHex(sc3.header) == "c8d3bced6b94ddee42f40213ea1866ce", "MULT invertito = cattura")
check((try? IdealProtocol.scene(effect: 0, reversed: false, speed: 50, colors: Array(repeating: .red, count: 7), brightness: 50)) == nil, "MULT 7 colori rifiutato (MTU 23)")
check((try? IdealProtocol.scene(effect: 12, reversed: false, speed: 50, colors: [.red], brightness: 50)) == nil, "MULT effetto 12 rifiutato")
check(level(sc1.header, .command) == .experimental, "MULT sperimentale")
check(level(try! IdealProtocol.effect(mode: 3, reversed: false, speed: 50, foreground: .red, background: .blue, brightness: 50), .command) == .experimental, "SGLS modalità 3 sperimentale")
check(try! IdealProtocol.diyPixel(index: 5, color: .red, brightness: 50, mode: 1, speed: 30)[8...9] == [0x01, 0x1E], "DOOD respiro velocità 30")
check((try? IdealProtocol.diyPixel(index: 5, color: .red, brightness: 50, mode: 0, speed: 0)) == nil, "DOOD velocità 0 rifiutata")

// MARK: Editor su mappa
let mp: [MappedPoint] = [
    MappedPoint(index: 0, x: 0.1, y: 0.5, confidence: 1, area: 4),
    MappedPoint(index: 1, x: 0.5, y: 0.5, confidence: 1, area: 4),
    MappedPoint(index: 1, x: 0.9, y: 0.9, confidence: 1, area: 4),   // seconda fila (Y)
    MappedPoint(index: nil, x: 0.3, y: 0.3, confidence: 0, area: 4),
]
check(MapPainter.nearestIndex(points: mp, x: 52, y: 50, width: 100, height: 100, maxDistance: 10) == 1, "mappa: punto più vicino")
check(MapPainter.nearestIndex(points: mp, x: 30, y: 30, width: 100, height: 100, maxDistance: 10) == nil, "mappa: punto senza indice ignorato")
let masked = MapPainter.apply(points: mp, to: [RGB](repeating: .black, count: 3), color: .red, background: .blue) { x, _ in x > 0.8 }
check(masked == [.blue, .red, .black], "mappa: maschera testo, Y basta una copia, non mappati intatti")
check(MapPainter.previewLevel(mode: .flash, speed: 50, time: 0) == 1, "anteprima lampeggio acceso")
check(MapPainter.previewLevel(mode: .static, speed: 50, time: 1.23) == 1, "anteprima fisso")
check(MapPainter.previewPeriod(speed: 100) < MapPainter.previewPeriod(speed: 1), "anteprima: 100 più veloce")

// MARK: Mappatura — codifica
let plan200 = MappingPlan(ledCount: 200)
check(plan200.bits == 8, "mappatura: 8 bit per 200 LED", "\(plan200.bits)")
check(plan200.frames.count == 18, "mappatura: 18 fotogrammi per 200 LED")
check(MappingPlan(ledCount: 400).bits == 9, "mappatura: 9 bit per 400 LED")
check(MappingPlan(ledCount: 255).bits == 8 && MappingPlan(ledCount: 256).bits == 9, "mappatura: confine 255/256")
var allCodesUnique = Set<Int>()
for i in 0..<200 { allCodesUnique.insert(MappingPlan.code(forIndex: i)) }
check(allCodesUnique.count == 200 && !allCodesUnique.contains(0), "mappatura: codici unici, mai 0")
check(plan200.pattern(for: .allOn, on: .green).allSatisfy { $0 == .green }, "mappatura: tutto acceso")
for i in [0, 1, 99, 199] {
    let pairs: [(Float, Float)] = (0..<plan200.bits).map { b in
        plan200.isOn(index: i, in: .bit(b, inverted: false)) ? (200, 10) : (10, 200)
    }
    check(plan200.decode(pairs).index == i, "mappatura: decodifica indice \(i)")
}
check(plan200.decode([(100, 98)] + Array(repeating: (200, 10), count: 7)).index == nil, "mappatura: bit indeciso scartato")
check(plan200.decode(Array(repeating: (200, 10), count: 8)).index == nil, "mappatura: codice 255 fuori range scartato")

// MARK: Mappatura — immagini sintetiche (2 file a Y: ogni indice in due posizioni)
struct LCG { var s: UInt64; mutating func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) } }
let W = 260, H = 60
var ledPositions: [(Int, Double, Double)] = []
for i in 0..<40 {
    ledPositions.append((i, 5 + Double(i) * 6.2, 15))   // fila 1
    ledPositions.append((i, 5 + Double(i) * 6.2, 45))   // fila 2, stesso indice
}
let plan40 = MappingPlan(ledCount: 40)
var rng = LCG(s: 42)
func render(_ frame: MappingPlan.Frame) -> GrayImage {
    var img = GrayImage(width: W, height: H)
    for y in 0..<H { for x in 0..<W { img[x, y] = 20 + Float(x) * 0.1 + rng.next() * 6 } }   // ambiente + rumore
    // riflesso fisso sul pavimento, presente in tutti i fotogrammi
    for y in 28...32 { for x in 100...140 { img[x, y] += 60 } }
    for (i, lx, ly) in ledPositions where plan40.isOn(index: i, in: frame) {
        for y in max(0, Int(ly) - 3)...min(H - 1, Int(ly) + 3) {
            for x in max(0, Int(lx) - 3)...min(W - 1, Int(lx) + 3) {
                let d2 = (Double(x) - lx) * (Double(x) - lx) + (Double(y) - ly) * (Double(y) - ly)
                img[x, y] = min(255, img[x, y] + Float(180 * exp(-d2 / 2.0)))
            }
        }
    }
    return img
}
var synthetic: [MappingPlan.Frame: GrayImage] = [:]
for f in plan40.frames { synthetic[f] = render(f) }
let mapped = MappingDecoder.decode(plan: plan40, frames: synthetic)
let summary = MappingDecoder.summarize(mapped, ledCount: 40)
check(mapped.count == 80, "mappatura sintetica: 80 punti trovati", "\(mapped.count)")
check(summary.decoded == 80, "mappatura sintetica: tutti decodificati", "\(summary.decoded)")
check(summary.missing.isEmpty, "mappatura sintetica: nessun indice mancante", "\(summary.missing)")
check(summary.duplicatedIndices == 40 && summary.conflicts == 0, "mappatura sintetica: ogni indice due volte (Y)")
var positionsOK = true
for p in mapped {
    guard let i = p.index else { positionsOK = false; continue }
    let expectedX = (5 + Double(i) * 6.2) / Double(W - 1)
    if abs(p.x - expectedX) > 0.01 { positionsOK = false }
}
check(positionsOK, "mappatura sintetica: posizioni coerenti con gli indici")
check(BlobDetector.detect(GrayImage(width: 10, height: 10, fill: 30)).isEmpty, "blob: immagine uniforme senza punti")

// LED fusi nell'immagine (2,5 px di distanza): la decodifica per pixel li separa
let plan8 = MappingPlan(ledCount: 8)
let merged: [(Int, Double, Double)] = [(3, 20, 10), (4, 22.5, 10), (6, 40, 10)]
func renderMerged(_ frame: MappingPlan.Frame) -> GrayImage {
    var img = GrayImage(width: 60, height: 20, fill: 25)
    for (i, lx, ly) in merged where plan8.isOn(index: i, in: frame) {
        for y in 0..<20 { for x in 0..<60 {
            let d2 = (Double(x) - lx) * (Double(x) - lx) + (Double(y) - ly) * (Double(y) - ly)
            img[x, y] = min(255, img[x, y] + Float(180 * exp(-d2 / 2.0)))
        } }
    }
    return img
}
var mergedFrames: [MappingPlan.Frame: GrayImage] = [:]
for f in plan8.frames { mergedFrames[f] = renderMerged(f) }
let mergedPts = MappingDecoder.decode(plan: plan8, frames: mergedFrames)
let mergedIdx = Set(mergedPts.compactMap { $0.index })
check(mergedIdx == [3, 4, 6], "mappatura: LED fusi separati per codice", "\(mergedPts.map { ($0.index ?? -1, Int($0.x * 59)) })")

// Riflesso debole di un LED: scartato se esistono già le copie attese
let plan4 = MappingPlan(ledCount: 4)
func renderReflect(_ frame: MappingPlan.Frame) -> GrayImage {
    var img = GrayImage(width: 60, height: 20, fill: 20)
    let spots: [(Double, Double, Float)] = [(10, 5, 180), (30, 5, 180), (50, 15, 25)]   // 2 copie + riflesso
    if plan4.isOn(index: 1, in: frame) {
        for (lx, ly, amp) in spots {
            for y in 0..<20 { for x in 0..<60 {
                let d2 = (Double(x) - lx) * (Double(x) - lx) + (Double(y) - ly) * (Double(y) - ly)
                img[x, y] += amp * Float(exp(-d2 / 2.0))
            } }
        }
    }
    return img
}
var reflFrames: [MappingPlan.Frame: GrayImage] = [:]
for f in plan4.frames { reflFrames[f] = renderReflect(f) }
let reflPts = MappingDecoder.decode(plan: plan4, frames: reflFrames).filter { $0.index == 1 }
check(reflPts.count == 2, "mappatura: riflesso debole scartato", "\(reflPts.count)")

// MARK: Identità LED e multicentralina
let cA = ControllerConfig(name: "A", bleName: "ISP-A", ledCount: 200, order: 0)
let cB = ControllerConfig(name: "B", bleName: "ISP-B", ledCount: 400, order: 1)
let cC = ControllerConfig(name: "C", bleName: "ISP-C", ledCount: 500, order: 2)   // oltre 400: limitato
let cD = ControllerConfig(name: "D", bleName: "ISP-D", ledCount: 600, order: 3, enabled: false)
let book = Codebook(controllers: [cC, cA, cB, cD])
check(book.total == 200 + 400 + 400, "codebook: totale con limite 400 e centralina disattivata", "\(book.total)")
check(book.plan.bits == 10, "codebook: 10 bit per 1000 LED", "\(book.plan.bits)")
check(book.globalIndex(LEDKey(controller: cB.id, pixel: 0)) == 200, "codebook: offset seconda centralina")
check(book.globalIndex(LEDKey(controller: cA.id, pixel: 200)) == nil, "codebook: pixel fuori range")
var roundTrip = true
for g in stride(from: 0, to: book.total, by: 37) {
    guard let k = book.key(forGlobal: g), book.globalIndex(k) == g else { roundTrip = false; break }
}
check(roundTrip, "codebook: andata e ritorno indici globali")
let t1 = book.targets(for: .bit(0, inverted: false), on: .green)
check(t1[cA.id]?.count == 200 && t1[cB.id]?.count == 400 && t1[cD.id] == nil, "codebook: disegni per centralina")
check(book.plan.isOn(index: book.globalIndex(LEDKey(controller: cB.id, pixel: 5))!, in: .bit(0, inverted: false)) == (t1[cB.id]![5] == .green), "codebook: fotogramma coerente con i codici globali")
let split = FrameSplitter.split([LEDKey(controller: cA.id, pixel: 3): .red], controllers: [cA, cB])
check(split[cA.id]?[3] == .red && split[cA.id]?[4] == .black && split[cB.id]?.count == 400, "split: colori per centralina")
let book1600 = Codebook(controllers: (0..<4).map { ControllerConfig(name: "C\($0)", bleName: "ISP-\($0)", ledCount: 400, order: $0) })
check(book1600.total == 1600 && book1600.plan.bits == 11 && book1600.plan.frames.count == 24, "codebook: 4×400 = 1600 LED, 11 bit, 24 fotogrammi")

// MARK: Geometria 3D
let target3 = SIMD3<Double>(1.0, 0.5, -2.0)
let camA = SIMD3<Double>(0, 0, 0), camB = SIMD3<Double>(2, 0, 0), camC = SIMD3<Double>(0, 1.5, 1)
let rA = Ray(origin: camA, direction: target3 - camA), rB = Ray(origin: camB, direction: target3 - camB)
if let cp = Triangulation.closestPoint(rA, rB) {
    check(simd_distance(cp.point, target3) < 1e-6 && cp.gap < 1e-6, "triangolazione: due raggi")
} else { check(false, "triangolazione: due raggi") }
let ls = Triangulation.leastSquares([rA, rB, Ray(origin: camC, direction: target3 - camC)])
check(ls.map { simd_distance($0, target3) < 1e-6 } == true, "triangolazione: minimi quadrati")
check(Triangulation.closestPoint(rA, Ray(origin: camB, direction: rA.direction)) == nil, "triangolazione: raggi paralleli")
// Pixel a Y: due LED fisici, visti da 3 viste; più un punto da profondità
let keyY = LEDKey(controller: cA.id, pixel: 7)
let pL = SIMD3<Double>(1.5, 0.6, 0.85), pR = SIMD3<Double>(1.5, 0.6, -0.85)
let cams: [SIMD3<Double>] = [SIMD3(4, 1.2, 0), SIMD3(3, 1.2, 3), SIMD3(3, 1.2, -3)]
var obsY: [LEDObservation] = []
for (v, cam) in cams.enumerated() {
    obsY.append(LEDObservation(key: keyY, view: v, point: nil, ray: Ray(origin: cam, direction: pL - cam)))
    obsY.append(LEDObservation(key: keyY, view: v, point: nil, ray: Ray(origin: cam, direction: pR - cam)))
}
let recY = LEDReconstructor.reconstruct(obsY, maxCopies: 2)
check(recY.count == 2, "ricostruzione: due posizioni per un pixel a Y", "\(recY.count)")
check(recY.contains { simd_distance($0.position, pL) < 0.02 } && recY.contains { simd_distance($0.position, pR) < 0.02 }, "ricostruzione: posizioni corrette",
      "\(recY.map { $0.position })")
let recDepth = LEDReconstructor.reconstruct([LEDObservation(key: keyY, view: 0, point: pL, ray: nil)], maxCopies: 2)
check(recDepth.count == 1 && recDepth[0].views == 1, "ricostruzione: un punto di profondità basta")
let recOneRay = LEDReconstructor.reconstruct([LEDObservation(key: keyY, view: 0, point: nil, ray: rA)], maxCopies: 2)
check(recOneRay.isEmpty, "ricostruzione: un solo raggio non basta")
// Allineamento: nuvola lungo una direzione a 30° → asse x dell'auto
let ang = 30.0 * Double.pi / 180
let cloud = (0..<50).map { i -> SIMD3<Double> in
    let s = Double(i) / 49 * 4 - 2
    return SIMD3(5 + s * cos(ang), 1 + 0.1 * Double(i % 3), 2 + s * sin(ang))
}
let al = AutoAlign.fit(cloud)
let alongX = cloud.map { al.toCar($0) }
check(alongX.allSatisfy { abs($0.z) < 0.01 }, "allineamento: asse principale su x", "\(alongX.map { $0.z }.max() ?? 0)")
check(ZoneClassifier.zone(of: SIMD3(1.9, 0.6, 0)) == .front && ZoneClassifier.zone(of: SIMD3(-1.9, 0.6, 0)) == .rear
      && ZoneClassifier.zone(of: SIMD3(0, 0.6, 0.8)) == .left && ZoneClassifier.zone(of: SIMD3(0, 0.6, -0.8)) == .right
      && ZoneClassifier.zone(of: SIMD3(0, 1.3, 0)) == .roof, "zone dell'auto")

// MARK: Motore effetti
let ctrl = UUID()
var effPts: [EffectPoint] = (0..<40).map { EffectPoint(key: LEDKey(controller: ctrl, pixel: $0), position: SIMD3(-2 + Double($0) * 0.1, 0.5, 0.8)) }
effPts.append(EffectPoint(key: LEDKey(controller: ctrl, pixel: 20), position: SIMD3(1.9, 0.5, -0.8)))   // copia a Y del pixel 20 (frontale)
let ctx = EffectContext(points: effPts)
var solidP = EffectParams(); solidP.kind = .solid; solidP.colors = [.red]; solidP.intensity = 1
let solidOut = EffectEngine.render(EffectProgram(name: "s", layers: [EffectLayer(params: solidP)]), context: ctx, time: 3)
check(solidOut.count == 40 && solidOut.values.allSatisfy { $0 == .red }, "effetti: statico, un colore per pixel logico")
var scanP = EffectParams(); scanP.kind = .scanFrontBack; scanP.colors = [.red, .black]; scanP.intensity = 1; scanP.speed = 0.5; scanP.width = 0.1
let s0 = EffectEngine.render(EffectProgram(name: "scan", layers: [EffectLayer(params: scanP)]), context: ctx, time: 0.5)
let s1 = EffectEngine.render(EffectProgram(name: "scan", layers: [EffectLayer(params: scanP)]), context: ctx, time: 1.2)
func brightestPixel(_ m: [LEDKey: RGB]) -> Int { m.max { $0.value.r < $1.value.r }!.key.pixel }
check(brightestPixel(s1) > brightestPixel(s0), "effetti: la scansione avanza lungo l'asse", "\(brightestPixel(s0)) → \(brightestPixel(s1))")
check(EffectEngine.render(EffectProgram(name: "scan", layers: [EffectLayer(params: scanP)]), context: ctx, time: 0.5) == s0, "effetti: deterministico")
var rb = EffectParams(); rb.kind = .rainbow; rb.intensity = 1
let rbOut = EffectEngine.render(EffectProgram(name: "rb", layers: [EffectLayer(params: rb)]), context: ctx, time: 0)
check(Set(rbOut.values).count > 10, "effetti: arcobaleno varia nello spazio")
// Pixel 20 a Y: una copia sul lato sinistro (rosso), una sul frontale (blu) → media
var leftRed = EffectParams(); leftRed.kind = .solid; leftRed.colors = [.red]; leftRed.intensity = 1
var rightBlue = EffectParams(); rightBlue.kind = .solid; rightBlue.colors = [.blue]; rightBlue.intensity = 1
let zoned = EffectEngine.render(EffectProgram(name: "z", layers: [EffectLayer(zone: .left, params: leftRed), EffectLayer(zone: .front, params: rightBlue)]), context: ctx, time: 0)
check(zoned[LEDKey(controller: ctrl, pixel: 20)] == RGB(r: 128, g: 0, b: 128), "effetti: pixel a Y con zone diverse = colore medio",
      "\(String(describing: zoned[LEDKey(controller: ctrl, pixel: 20)]))")
check(zoned[LEDKey(controller: ctrl, pixel: 10)] == .red, "effetti: livello per zona")
var prog = EffectProgram(name: "p", layers: [EffectLayer(params: solidP)])
prog.paint[LEDKey(controller: ctrl, pixel: 5)] = .green
check(EffectEngine.render(prog, context: ctx, time: 0)[LEDKey(controller: ctrl, pixel: 5)] == .green, "effetti: pittura sopra i livelli")
var po = EffectParams(); po.kind = .powerOn; po.colors = [.red]; po.intensity = 1; po.speed = 1
let poStart = EffectEngine.render(EffectProgram(name: "po", layers: [EffectLayer(params: po)]), context: ctx, time: 0)
let poEnd = EffectEngine.render(EffectProgram(name: "po", layers: [EffectLayer(params: po)]), context: ctx, time: 2)
check(poStart.values.filter { $0 != .black }.count < 5 && poEnd.values.allSatisfy { $0 == .red || $0.r > 200 }, "effetti: accensione progressiva")
let grad = EffectEngine.gradient(keys: Set((1..<40).map { LEDKey(controller: ctrl, pixel: $0) }), context: ctx, axis: .frontBack, from: .red, to: .blue)
check(grad[LEDKey(controller: ctrl, pixel: 1)] == .red && grad[LEDKey(controller: ctrl, pixel: 39)] == .blue, "gradiente lungo l'asse")
check(EffectEngine.hsv(0, 1, 1) == .red && EffectEngine.hsv(2.0 / 3.0, 1, 1) == .blue, "hsv")
if let data = try? JSONEncoder().encode(prog), let back = try? JSONDecoder().decode(EffectProgram.self, from: data) {
    check(back == prog, "programma effetti: salvataggio JSON")
} else { check(false, "programma effetti: salvataggio JSON") }

// MARK: Forma dell'auto (modello provvisorio)
check(abs(CarShape.topY(-0.5) - 1.415) < 0.02, "forma: tetto a 1,41 m")
check(abs(CarShape.topY(2.015) - 0.62) < 0.01 && CarShape.topY(1.5) < 0.95, "forma: muso e cofano bassi")
check(abs(CarShape.bottomY(CarShape.frontAxle) - (CarShape.wheelRadius + CarShape.archRadius)) < 0.01, "forma: passaruota sopra la ruota")
check(CarShape.isCabin(-0.5) && !CarShape.isCabin(1.5), "forma: abitacolo e cofano")
check(CarShape.stations.count > 50 && CarShape.halfSection(0).count == 12, "forma: sezioni")
var maxW = 0.0
for x in CarShape.stations { for p in CarShape.halfSection(x) { maxW = max(maxW, p.z) } }
check(maxW <= CarDimensions.width / 2 + 0.01, "forma: larghezza entro 1,74 m", "\(maxW)")
var monotoneOK = true
for i in 0..<200 {
    let x0 = -2.0 + Double(i) * 0.02
    if abs(CarShape.topY(x0 + 0.02) - CarShape.topY(x0)) > 0.06 { monotoneOK = false }
}
check(monotoneOK, "forma: profilo senza salti")

// MARK: UUID (bug 2.0: iOS presenta FFF0 nella forma lunga)
check(IdealUUID.normalize("0000FFF0-0000-1000-8000-00805F9B34FB") == "FFF0", "uuid: forma lunga → corta")
check(IdealUUID.normalize("fff0") == "FFF0", "uuid: minuscole")
check(IdealUUID.normalize(IdealUUID.command) == IdealUUID.command, "uuid: 128 bit proprietario invariato")
check(CharacteristicRole.of("0000AE01-0000-1000-8000-00805F9B34FB") == .otaWrite, "uuid: AE01 lunga resta bloccata")

print("\n\(passed) superati, \(failures) falliti")
if let dir = CommandLine.arguments.dropFirst().first {
    try? "\(passed) superati, \(failures) falliti\n".write(toFile: dir + "/logic-summary.txt", atomically: true, encoding: .utf8)
}
exit(failures == 0 ? 0 : 1)
