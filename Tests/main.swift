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
      && ZoneClassifier.zone(of: SIMD3(0, 0.6, -0.8)) == .left && ZoneClassifier.zone(of: SIMD3(0, 0.6, 0.8)) == .right
      && ZoneClassifier.zone(of: SIMD3(0, 1.3, 0)) == .roof, "zone dell'auto")

// MARK: Motore effetti
let ctrl = UUID()
var effPts: [EffectPoint] = (0..<40).map { EffectPoint(key: LEDKey(controller: ctrl, pixel: $0), position: SIMD3(-2 + Double($0) * 0.1, 0.5, -0.8)) }
effPts.append(EffectPoint(key: LEDKey(controller: ctrl, pixel: 20), position: SIMD3(1.9, 0.5, 0.8)))   // copia a Y del pixel 20 (frontale)
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

// MARK: Catalogo effetti completo
check(EffectKind.allCases.count >= 45, "effetti: catalogo completo", "\(EffectKind.allCases.count)")
var allEffectsOK = true
var failingEffect = ""
for kind in EffectKind.allCases {
    var prm = EffectParams()
    prm.kind = kind
    prm.colors = kind.defaultColors
    prm.intensity = 1
    let pr = EffectProgram(name: kind.label, layers: [EffectLayer(params: prm)])
    for tt in [0.0, 0.37, 1.3, 7.7, 123.4] {
        let a = EffectEngine.render(pr, context: ctx, time: tt)
        let b = EffectEngine.render(pr, context: ctx, time: tt)
        if a.count != 40 || a != b { allEffectsOK = false; failingEffect = kind.rawValue }
    }
    if kind.label.isEmpty || kind.icon.isEmpty || kind.defaultColors.isEmpty { allEffectsOK = false; failingEffect = kind.rawValue }
}
check(allEffectsOK, "effetti: ognuno produce un colore per pixel ed è deterministico", failingEffect)
for kind in EffectKind.allCases where kind != .solid && kind != .gradient && kind != .lightning {
    var prm = EffectParams(); prm.kind = kind; prm.colors = kind.defaultColors; prm.intensity = 1; prm.speed = 0.7
    let pr = EffectProgram(name: "", layers: [EffectLayer(params: prm)])
    var frames = Set<[RGB]>()
    for k in 0..<12 {
        let m = EffectEngine.render(pr, context: ctx, time: Double(k) * 0.43)
        frames.insert((0..<40).map { m[LEDKey(controller: ctrl, pixel: $0)] ?? .black })
    }
    if frames.count < 2 && kind != .powerOn && kind != .powerDown { allEffectsOK = false; failingEffect = "statico: \(kind.rawValue)" }
}
check(allEffectsOK, "effetti animati: cambiano nel tempo", failingEffect)
var bounceP = EffectParams(); bounceP.kind = .bounce; bounceP.colors = [.red, .black]; bounceP.intensity = 1; bounceP.speed = 0.5; bounceP.width = 0.15
let bp = EffectProgram(name: "", layers: [EffectLayer(params: bounceP)])
let b1 = brightestPixel(EffectEngine.render(bp, context: ctx, time: 1.0)), b2 = brightestPixel(EffectEngine.render(bp, context: ctx, time: 2.0))
check(b1 > 30 && b2 < 10, "supercar: va e torna", "\(b1) \(b2)")
var polP = EffectParams(); polP.kind = .police; polP.colors = [.red, .blue]; polP.intensity = 1; polP.axis = .frontBack; polP.speed = 1
let pol = EffectEngine.render(EffectProgram(name: "", layers: [EffectLayer(params: polP)]), context: ctx, time: 0.02)
check(pol.values.contains(.red) || pol.values.contains(.blue), "polizia: lampeggi rosso/blu")
check(abs(EffectEngine.valueNoise(1.2, 3.4, 5.6) - EffectEngine.valueNoise(1.2, 3.4, 5.6)) < 1e-12
      && (0...1).contains(EffectEngine.valueNoise(0.3, 9.1, -2.2)), "rumore deterministico in 0…1")
check(EffectEngine.paletteLinear([.red, .blue], 0) == .red && EffectEngine.paletteLinear([.red, .blue], 1) == .blue, "tavolozza lineare")

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
let profileCtrl: [(Double, Double)] = [(-1.0, 0.0), (0.0, 1.0), (1.0, 1.0), (2.0, 0.0), (3.0, 0.2)]
for i in 0...300 {
    let x0 = -1.0 + Double(i) * 0.0133
    let y0 = CarShape.interp(profileCtrl, x0)
    if y0 < -1e-9 || y0 > 1.0 + 1e-9 { monotoneOK = false }   // nessuna oscillazione oltre i punti
}
check(monotoneOK, "forma: interpolazione senza oscillazioni")

// MARK: UUID (bug 2.0: iOS presenta FFF0 nella forma lunga)
check(IdealUUID.normalize("0000FFF0-0000-1000-8000-00805F9B34FB") == "FFF0", "uuid: forma lunga → corta")
check(IdealUUID.normalize("fff0") == "FFF0", "uuid: minuscole")
check(IdealUUID.normalize(IdealUUID.command) == IdealUUID.command, "uuid: 128 bit proprietario invariato")
check(CharacteristicRole.of("0000AE01-0000-1000-8000-00805F9B34FB") == .otaWrite, "uuid: AE01 lunga resta bloccata")

// MARK: Convenzione assi (2.3: sinistra = −z come glTF/SceneKit)
check(AxisFrame.app.toApp(SIMD3(1, 2, 3)) == SIMD3(1, 2, 3) && !AxisFrame.app.isMirror, "assi: sistema app invariato")
let zUp = AxisFrame(front: SIMD3(0, -1, 0), up: SIMD3(0, 0, 1), left: SIMD3(1, 0, 0))   // es. Blender con auto verso −Y
check(zUp.isValid && zUp.toApp(SIMD3(0, -2, 1)) == SIMD3(2, 1, 0) && zUp.toApp(SIMD3(1, 0, 0)) == SIMD3(0, 0, -1), "assi: conversione da z-alto")
check(AxisFrame(front: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), left: SIMD3(0, 0, 1)).isMirror, "assi: sinistra +Z è una riflessione")
check(AxisFrame.axis("-z") == SIMD3(0, 0, -1) && AxisFrame.axis("+X") == SIMD3(1, 0, 0) && AxisFrame.axis("W") == nil, "assi: lettura stringhe")

// MARK: Layout LED di progetto
let layoutJSON = """
{"schema_version":1,"coordinate_system":{"format":"glTF","unit":"meter","up":"+Y","vehicle_front":"+X","vehicle_left":"-Z"},
 "led_index_base":0,"physical_led_count":6,"topology":"mirrored_y","controllers":[
 {"id":"A","address_count":2,"physical_led_count":4,"branch_count":2,"addresses":[
   {"index":0,"zone":"tetto","targets":[{"branch":"left","position":[-1.0,1.4,-0.3]},{"branch":"right","position":[-1.0,1.4,0.3]}]},
   {"index":1,"zone":"tetto","targets":[{"branch":"left","position":[-0.9,1.4,-0.3]},{"branch":"right","position":[-0.9,1.4,0.3]}]}]},
 {"id":"B","address_count":3,"addresses":[{"index":2,"zone":"cofano","targets":[{"position":[1.5,0.9,-0.2]},{"position":[1.5,0.9,0.2]}]}]}]}
"""
do {
    let r = try LEDLayoutImport.parse(Data(layoutJSON.utf8))
    check(r.controllers.count == 2 && r.controllers[0].addressCount == 2 && r.controllers[1].addressCount == 3, "layout: centraline e indirizzi")
    check(r.physicalCount == 6 && r.logicalCount == 3, "layout: LED fisici e pixel logici")
    let left0 = r.points.first { $0.controller == 0 && $0.pixel == 0 && $0.branch == "left" }
    check(left0?.position == SIMD3(-1.0, 1.4, -0.3) && ZoneClassifier.zone(of: SIMD3(0, 0.6, left0!.position.z)) == .left, "layout: ramo sinistro resta a −z (sinistra)")
    check(r.points.filter { $0.controller == 1 }.allSatisfy { $0.pixel == 2 && $0.zone == "cofano" }, "layout: zona e indice")
    check(r.controllers[1].branches == 2, "layout: copie a Y dedotte dai target")
    check(r.warnings.contains { $0.contains("B") }, "layout: avviso indirizzi senza posizione")
} catch { check(false, "layout: lettura", "\(error)") }
func layoutFails(_ json: String) -> LEDLayoutImport.Failure? {
    do { _ = try LEDLayoutImport.parse(Data(json.utf8)); return nil } catch { return error as? LEDLayoutImport.Failure }
}
check(layoutFails(#"{"controllers":[{"id":"A","addresses":[{"index":0,"targets":[]},{"index":0,"targets":[]}]}]}"#) == .duplicate("A", 0), "layout: indirizzo ripetuto rifiutato")
check(layoutFails(#"{"controllers":[{"id":"A","address_count":401,"addresses":[]}]}"#) == .tooManyAddresses("A", 401), "layout: oltre 400 indirizzi rifiutato")
check(layoutFails(#"{"controllers":[{"id":"A","addresses":[{"index":0,"targets":[{"position":[0,1]}]}]}]}"#) == .badPosition("A", 0), "layout: posizione incompleta rifiutata")
check(layoutFails(#"{"controllers":[{"id":"A","addresses":[{"index":0,"targets":[{"position":[50,0,0]}]}]}]}"#) == .badPosition("A", 0), "layout: posizione fuori dall'auto rifiutata")
check(layoutFails(#"{"controllers":[]}"#) == .noControllers, "layout: file vuoto")
check(layoutFails(#"{"coordinate_system":{"up":"+Y","vehicle_front":"+Y"},"controllers":[{"id":"A","addresses":[]}]}"#) == .badAxes, "layout: assi doppi rifiutati")
if let one = try? LEDLayoutImport.parse(Data(#"{"led_index_base":1,"controllers":[{"id":"A","addresses":[{"index":1,"targets":[{"position":[0,1,0]}]}]}]}"#.utf8)) {
    check(one.points.first?.pixel == 0, "layout: base indice 1 convertita")
} else { check(false, "layout: base indice 1") }

// MARK: Modello glTF binario
func makeGLB(json: String, bin: [UInt8]) -> Data {
    var j = Array(json.utf8); while j.count % 4 != 0 { j.append(0x20) }
    var b = bin; while b.count % 4 != 0 { b.append(0) }
    func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    var out: [UInt8] = Array("glTF".utf8) + le(2) + le(UInt32(12 + 8 + j.count + 8 + b.count))
    out += le(UInt32(j.count)) + le(0x4E4F534A) + j
    out += le(UInt32(b.count)) + le(0x004E4942) + b
    return Data(out)
}
var triBin: [UInt8] = []
for f in [Float(0), 0, 0, 1, 0, 0, 0, 1, 0] { let v = f.bitPattern; triBin += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
triBin += [0, 0, 1, 0, 2, 0, 0, 0]
let triJSON = """
{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],
 "nodes":[{"name":"Carrozzeria","mesh":0,"translation":[0,1,0]},{"name":"LED_A_000_left","mesh":0}],
 "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],
 "materials":[{"name":"Vernice","pbrMetallicRoughness":{"baseColorFactor":[0.1,0.2,0.3,1],"metallicFactor":0.7},"emissiveFactor":[1,0,0],"extensions":{"KHR_materials_emissive_strength":{"emissiveStrength":3}}}],
 "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
 "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],
 "buffers":[{"byteLength":44}]}
"""
let triGLB = makeGLB(json: triJSON, bin: triBin)
do {
    let m = try GLTFModel.load(triGLB, skipNode: { $0.hasPrefix("LED_") })
    check(m.parts.count == 1 && m.skippedNodes == 1, "glb: nodi LED esclusi")
    check(m.parts[0].positions == [SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(0, 2, 0)], "glb: traslazione del nodo applicata")
    check(m.parts[0].indices == [0, 1, 2], "glb: indici a 16 bit")
    check(m.materials[0].metallic == 0.7 && m.materials[0].roughness == 1 && m.materials[0].emissiveStrength == 3, "glb: materiale PBR")
    let mir = try GLTFModel.load(triGLB, frame: AxisFrame(front: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), left: SIMD3(0, 0, 1)))
    check(mir.parts.count == 2 && mir.parts[0].indices == [0, 2, 1], "glb: riflessione inverte i triangoli")
} catch { check(false, "glb: lettura", "\(error)") }
check((try? GLTFModel.load(Data("ciao".utf8))) == nil, "glb: file non glb rifiutato")
var broken = [UInt8](triGLB); broken[broken.count - 4] = 9   // terzo indice → vertice 9 inesistente
check((try? GLTFModel.load(Data(broken))) == nil, "glb: indici fuori intervallo rifiutati")
check((try? GLTFModel.load(makeGLB(json: triJSON.replacingOccurrences(of: "\"buffers\":[{", with: "\"extensionsRequired\":[\"KHR_draco_mesh_compression\"],\"buffers\":[{"), bin: triBin))) == nil,
      "glb: compressione Draco segnalata come non supportata")

// MARK: File reali del progetto (se presenti nel repository)
if let data = FileManager.default.contents(atPath: "Resources/Audi_A1_LED1600.json") {
    if let r = try? LEDLayoutImport.parse(data) {
        check(r.controllers.count == 4 && r.physicalCount == 1600 && r.logicalCount == 800, "progetto A1: 4 × 200 pixel, 1600 LED")
        check(r.controllers.allSatisfy { $0.addressCount == 200 && $0.branches == 2 } && r.warnings.isEmpty, "progetto A1: pacchi a Y completi", r.warnings.joined(separator: "; "))
        let lefts = r.points.filter { $0.branch == "left" }
        check(!lefts.isEmpty && lefts.allSatisfy { $0.position.z <= 0 }, "progetto A1: ramo sinistro sul lato sinistro")
    } else { check(false, "progetto A1: layout leggibile") }
}
if let data = FileManager.default.contents(atPath: "Resources/Audi_A1_LED1600.glb") {
    do {
        let m = try GLTFModel.load(data, skipNode: { $0.hasPrefix("LED_") })
        check(m.skippedNodes == 1600 && m.triangleCount > 50_000, "progetto A1: modello letto senza i 1600 marcatori", "\(m.skippedNodes) \(m.triangleCount)")
        check(abs(m.boundsMin.y) < 0.01 && abs(m.boundsMax.x - m.boundsMin.x - 4.12) < 0.05, "progetto A1: a terra, lungo ~4,1 m", "\(m.boundsMin) \(m.boundsMax)")
    } catch { check(false, "progetto A1: modello", "\(error)") }
}

// MARK: Pacchetto animazioni pre-calcolate
func packJSON(frames: [UInt8], count: Int, loop: Bool, fps: Int = 2, addresses: Int = 2) -> String {
    """
    {"schema_version":1,"pixel_format":"RGB8","packing":"frame_major_rgb","topology":"mirrored_y",
     "controller_order":[{"id":"A","address_count":\(addresses)}],
     "presets":[{"id":"t","name":"Test","fps":\(fps),"frame_count":\(count),"loop":\(loop),"frames_b64":"\(Data(frames).base64EncodedString())"}]}
    """
}
// 3 fotogrammi × 2 indirizzi: rosso/verde, poi grigio 100, poi blu
let packFrames: [UInt8] = [255, 0, 0, 0, 255, 0,  100, 100, 100, 100, 100, 100,  0, 0, 255, 0, 0, 255]
if let pack = try? FramePack.load(Data(packJSON(frames: packFrames, count: 3, loop: true).utf8)), let tp = pack.preset("t") {
    check(pack.frameBytes == 6 && tp.duration == 1.5, "pacchetto: dimensioni e durata")
    check(FramePack.frameIndex(tp, position: 0.6) == 1 && FramePack.frameIndex(tp, position: 1.6) == 0, "pacchetto: loop riparte")
    check(pack.colors(tp, frame: 0) == [[.red, .green]], "pacchetto: colori per indirizzo")
    var half = FramePack.Settings(); half.intensity = 0.5
    check(pack.colors(tp, frame: 1, settings: half)[0][0] == RGB(r: 50, g: 50, b: 50), "pacchetto: intensità")
    var tinted = FramePack.Settings(); tinted.tint = RGB(r: 0, g: 200, b: 255)
    check(pack.colors(tp, frame: 0, settings: tinted)[0][0] == RGB(r: 0, g: 200, b: 255), "pacchetto: colore unico segue la luminosità")
    var crazy = FramePack.Settings(); crazy.speed = 9; crazy.intensity = -3
    check(crazy.clamped.speed == 2 && crazy.clamped.intensity == 0, "pacchetto: limiti velocità/intensità")
    let cA = ControllerConfig(name: "A", bleName: "x", ledCount: 1, order: 0)
    let keyedColors = FramePack.keyed(pack.colors(tp, frame: 0), controllers: [cA])
    check(keyedColors.count == 1 && keyedColors[LEDKey(controller: cA.id, pixel: 0)] == .red, "pacchetto: A → prima centralina, entro i suoi pixel")
} else { check(false, "pacchetto: lettura") }
if let once = try? FramePack.load(Data(packJSON(frames: packFrames, count: 3, loop: false).utf8)), let op = once.preset("t") {
    check(FramePack.frameIndex(op, position: 99) == 2, "pacchetto: senza loop resta sull'ultimo fotogramma")
} else { check(false, "pacchetto: lettura senza loop") }
check((try? FramePack.load(Data(packJSON(frames: packFrames, count: 4, loop: true).utf8))) == nil, "pacchetto: fotogrammi mancanti rifiutati")
check((try? FramePack.load(Data(packJSON(frames: [], count: 1, loop: true, addresses: 401).utf8))) == nil, "pacchetto: oltre 400 indirizzi rifiutato")
if let data = FileManager.default.contents(atPath: "Resources/AudiLightStudio_Effetti.json") {
    if let pack = try? FramePack.load(data) {
        check(pack.presets.count == 60 && pack.controllerIDs == ["A", "B", "C", "D"] && pack.addressCounts == [200, 200, 200, 200],
              "pacchetto A1: 60 animazioni su A–D × 200")
    } else { check(false, "pacchetto A1: leggibile") }
}

// MARK: Allineamento della scansione al progetto e animazioni adattate
let regCtrl = UUID()
var designPts: [EffectPoint] = []
for i in 0..<60 {
    let x = -1.8 + Double(i) * 0.06, y = 0.4 + 0.9 * Double(i % 7) / 7
    designPts.append(EffectPoint(key: LEDKey(controller: regCtrl, pixel: i), position: SIMD3(x, y, -0.8)))
    designPts.append(EffectPoint(key: LEDKey(controller: regCtrl, pixel: i), position: SIMD3(x, y, 0.8)))   // copia a Y
}
// Scansione: auto ruotata di 2 rad, spostata e scala 1,02; le copie a Y arrivano in ordine inverso.
let trueA = CarAlignment(yaw: 2.0, offset: SIMD3(3, -1.2, 5), scale: 1.02)
func inverse(_ a: CarAlignment, _ car: SIMD3<Double>) -> SIMD3<Double> {
    let q = car / a.scale
    let c = cos(a.yaw), s = sin(a.yaw)
    return SIMD3(c * q.x - s * q.z, q.y, s * q.x + c * q.z) + a.offset
}
var scanPts = designPts.reversed().map { EffectPoint(key: $0.key, position: inverse(trueA, $0.position)) }
check(simd_distance(trueA.toCar(scanPts[0].position), designPts.last!.position) < 1e-9, "registrazione: inversa di prova corretta")
// 10 pixel montati diversamente dal progetto (spostati di 60 cm).
for i in 0..<20 { scanPts[i].position += SIMD3(0.6, 0, 0.3) }
if let fit = LayoutRegistration.fit(scan: scanPts, design: designPts) {
    let err = designPts[100...].map { simd_distance(fit.alignment.toCar(inverse(trueA, $0.position)), $0.position) }.max() ?? 1
    check(err < 0.005, "registrazione: ritrova rotazione, posizione e scala", "\(err)")
    check(fit.isGood && fit.total == 60 && fit.used == 50, "registrazione: pixel montati diversamente esclusi", fit.summary)
} else { check(false, "registrazione: stima") }
check(LayoutRegistration.fit(scan: scanPts, design: [EffectPoint(key: LEDKey(controller: UUID(), pixel: 0), position: .zero)]) == nil, "registrazione: nessun pixel in comune")


let adaptiveGolden: [String: String] = [
    "ignition_sweep": "88d4f9000000000000000000000000000000000000000000000000043761043761043761000000043761043761043761043761043761043761043761043761000000043761043761043761043761043761",
    "ice_scan": "20398919053008021000000007010d07010d07010d07010d07010d07020e3a7ecb21135400000007020e07010d07010d07010d07010d21135410031e07010d00000007010d07010d07010d07010d07010d",
    "ember_flow": "9242101005010f0501000000a93b07220c010f05018b31062b0f020f0501230d02913206000000110601100501c359150f05016624040f05011106014a1a03000000250e020f0501421703100601e36618",
    "aurora": "2e1c6232407b275f770000002d195e11645131447c295d7820094010624d1e686b2d527c0000000c5c4430246b20676e2e507c06462e0439233234762b175b000000295d781c073732397812645205422a",
    "diamond_rain": "01080e01080e5d91ab00000082c8e901090f6da9c6172a3401080e01080e01080e01080e00000001080e1c313c01080e01080e01080e07121a01080e01080e00000001080e01080e01080e01080e80c6e6",
    "golden_welcome": "00000000000000000000000000000000000008060277551fb8822e422a08422a08422a08000000422a08422a08422a08422a08422a08422a08422a08422a08000000422a08422a08422a08422a08422a08",
    "night_shutdown": "250847250847250847000000250847250847250847250847250847000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    "blue_comet": "010c140003062d434c00000000000000000071d8ff01101b010a12000203000101010d170000002b699402192c01090f000204000203000001000000235c85000000010b1400060b000204000101000001",
    "golden_tide": "110b02805515744b0f000000d58c1f1f1403c07d19110b02110b02a86b13140d039b6312000000110b02281a05110b02a76a1385550f8c5a10110b02472d08000000110b029e6819110b025b3a0aac6e14",
    "eclipse": "09021109021109021100000009021109021109021109021109021111031b15041e090211000000090211090211090211090211090211090211090211901a9d00000009021109021113042609021185189c",
    "redline": "6109091c010312010200000060060a200203120102120102120102120102120102750a0b000000130102210303490408120102ff191a120102120102ff211c000000360306a91110140102120102580609",
    "neon_grid": "17284b150f1f1d70c9000000a32467172343150f1f17274a16162b150f1f7d235a1511220000001d70c91723433e2a58171f3c1c1022150f1f9885ff7d1f53000000161428150f1f1c6cc3150f1f872058",
    "tidal": "0d746b0e73510c634a0000000542710a6fa8010b1311a2b80a575504386107599d075c9f0000000b5b43052a2913afba021523053c6913b5cb06323210898200000008423e13b5cc04222013bcdb06528b",
    "ultraviolet": "47437f7c1bf247427f0000003a3768120422420f8046417f3c286e46427f12042249108d0000003619677d1bf2231a4147437f45447b51119d12042350119b000000190c2f5512a51204224f119a120423",
    "crystal": "251b44251b431e1a3700000010171b0f161a1a192e262445241b4311171c12191e251b45000000251b442b234e1d193416182611171d77b0ca161827201a3b0000007592cc231b4014182410171b405e6c",
    "citrus": "11794811824e69611f00000053571f46511fb28c25145732655f1f384d2146511f13955a000000128a5311824e15a06018512d13935848521f58591f128c5400000011804d10774815a2621e4c28128a53",
    "orbit": "0f214e0d0d2a0f27590000000d03190d03190d03191404283e0d781b06351104211e063b0000000d03190d03190d03190e0f2e1355a94f119a380c6d0f031e0000000d03190d041b0e183f1464c30d061e",
    "heartbeat": "210204210204220204000000240204230204210204210204210204210204210204210204000000210204210204210204210204210204210204210204210204000000210204210204210204210204210204",
    "night_city": "716eb843478c2352980000002552972452976c488d5f3d817f33768168b272367995296c000000932a6d942a6c5c498f5b3e823b4b908a2e70ad519997296b0000007435797634783c69b2507ac53c7ac5",
    "galaxy": "12255865a1e5391b860000001225581225588454f55813ab12255896a7ff281f734c169d000000202169524db4122558122559301d7b1225581225581f21680000001225581225583e198d291f745b91d3",
    "collision": "0760a8000203000000000000000000000000000000021d32065596050102000000000000000000000000000000000000000000080104000000000000000000000000000000000000000000000000000000",
    "blueprint": "569cc5050a0d000000000000000000000000000000000000000000032440032440032440000000032440032440032440032440072b47032440032440032440000000032440032440032440032440032440",
    "retro_arcade": "3e64916630a17121a6000000a23d12a23d12a66e22a66e22a66e22a4561aa66b21a66e220000001e8f851e8f857121a67121a67222a3a23d12a23d12a66e220000006e7c4aa66e227121a61e8f857121a6",
    "pillars_to_roof": "1e063a13042614184800000010042014103b1d06381410391f073d11042015042914103900000018052e14123d1004201b6bda10042010042014042614103a0000001905311414411004201c79f3100420",
    "checkered": "4f5668090e1a4b53640000004b53648e98ad404758090e1a090e1a090e1a090e1a4b53640000004b5364090e1a8e98ad8e98ad8e98ad1d22308e98ad7a83970000004b5364090e1a8e98ad8e98ad8e98ad",
    "blue_hour": "0c2577061334091c7c000000040e3d040d330a2186194a7822658b0d27840c278c1c548d000000091e8c091e69071666061253091d870c2574061132091c7e000000040d3b040e360b2286194b7b23688c",
    "twin_trails": "1137711217351b13230000007c4b24b46f2a0c03160c0316113f7f4a2b1e0b03160f112d0000000f20480f1738170d1d25141b41261d5633200b03161014310000000f25520f1b3e190f1e2a171c4c2c1f",
    "meteor": "03071d02061706071e00000002051302051503081f38587c060d2905081a230e58040a27000000100d3f040a2736148603081f02071b250c57030516030a26000000030923030925080b30030a25030922",
    "theater": "3c0d203f184a23084000000023083f2308402c0a2b65165a6015588f545f2308404a10500000006816595f15580200022308405f31550f0316230840360c480000001e07342a094365212f470f4e290942",
    "sunset_exit": "4c0e284b0e284b0e280000004b0e284b0e284b0e284b0e284b0e28000000000000000000000000000000000000000000000000050200000000000000000000000000000000000000000000000000000000",
    "pinstripe": "1c4058000000000000000000061f330000002644560000000109105392b5000000000000000000051d300000000c1d2a000000010910457c9d000000000000000000051d300000000c1e2a000000010910",
    "sill_run": "00010000000000000000000000000000000003130c00000000000000010000000000000000000000000000000002110a00000000000000010000000000000000000000000000000002110a000000000000",
    "wheel_halo": "00000000000000000000000000000000000020133c000000000000000000000000000000000000000000000000221341000000000000000000000000000000000000000000000000180a2e000000000000",
    "roof_rays": "06010c06010c56231900000006010c06010c06010c06010c06010c06010c06010c3e181300000006010c06010c06010c06010c06010c06010c06010c41280900000006010c06010c06010c06010c06010c",
    "tail_fan": "0e01010e01010e01010000000e01010e01010e01010e0101ff37280e01010e01010e01010000000e01010e01010e01010e01013002050e01010e01010e01010000000e01010e01010e01010e0101300205",
    "bonnet_fan": "01080e37575f01080e00000001080e01080e01080e01080e01080e01080e1a524101080e00000001080e01080e01080e01080e01080e01080e1a4d3e01080e00000001080e01080e01080e01080e01080e",
    "glass_frame": "00070b0003052a3f470000000002032a3f470109102a3f47010d180005090109104b707f000000010e19527a8b01080f7db9d300030500060b010a12588294000000010e185f8da101070d74acc4000204",
    "rapid_trace": "19c58b00000000000000000000020300000000060b0217270a595900000000020407434c0000000000001ad497000000000000000000000305010d161bd99b000000000000000000000000000000000000",
    "flare_arch": "1407011407011407010000001407011407014b2606140701140701140701140701140701000000140701140701140701140701140701140701140701140701000000140701140701150701140701140701",
    "panels": "6332ba0f031d4c10940000001207226739c24c10940f031d4e14970f031d5713a95814ab0000005713a90f031d140b266b31cb0f031d0f031d28094e4a3b8800000028094e0f041e0f031d341a621a1430",
    "zipper": "25061317040b1c0e06000000ad6c150901052607132906158a461fa26317321211b36b1b0000001d040ed17a210d0802030101090104a26317321211b36b1b0000001d040ed17a210d0802030101090104",
    "outward": "00040700000000000000000015a26e0000000000000000000005090000000c6a6701070c000000000000000000032c4b149a680000000000000c6a6701070c000000000000000000032c4b149a68000000",
    "fold": "0000000000000000000000002f0a5c04010800000000000000000003010519053055319f00000000000000000047158802000400000003010519053055319f000000000000000000471588020004000000",
    "rain_up": "000000000000000408000000000203010b13000000000000031e2e00000000000000050a000000000204010c15000000000000032331000000000000000000000000000000000000000000000203000204",
    "laser_drift": "00000000000018052f0000000000000000003e0d7900000002000419052e00000018052f00000000000005010acb0a15210740000000000000440f840a021300000000000000000000000006010c7b0612",
    "moire": "293d4613030a618fa30000000101013c091e14030a440a22283b43a91a564567758d1647000000020001537b8d22333a39545f0301020406070501022130370000002c424b0000009116490d1416030506",
    "slow_magma": "d82e17ff7025ff772600000067050bff70254b0408b81e143f03071a0103230204ff7926000000320205340206ff6d241a0103ff5c218f0d0fed381aff4a1d000000480308ff6c246a050b7f080d5c040a",
    "paper_lantern": "6e4d209d6d2da1742d000000a0732d9f712d9f732d835e259c6b2d2b1f0c261a0b7d5724000000472617763f26742f28755421704a21704f209d6e2da0742d000000a0732d9e702da0732d805c249c692d",
    "snow_field": "233b48141f254e7d94000000517c9114252f15314515354c1b405a153247163850163a5400000015354c15334814273314232b141f251639531b415c437a9b000000152b3a192f3c141f24141d21141e22",
    "prismatic": "1e7f4a31592f19965a0000001d5855179e635e15ad3826776316bc53157a5d15aa6216bb000000bb42098c301419985b983d0b227141b03d0a8d3014ba410900000037522a863b0d1871561b8b5217875b",
    "city_show": "7669b2494589215399000000235398225398604287584084793477314e933e498e686ab4000000902b6e933275882e718b2d706f377a140e1e867ae96d1b4a000000151226140d1e1a5daa140d1e761c4f",
    "ice_show": "0d2782091c40081971000000051048030a2c0a1f89153f671d578103092a07186b12378e0000001a4f860b238c1c5375091f8b091d67151b27121f2a143149000000142f45143047143149142e45132b3f",
    "fire_show": "aa1712ff541fff6523000000560409ff78265b040a940e104e040872060c4c0408550409000000fa401b3402054703087f080d3e0307100501120601421703000000230d021005013b1503110601c55815",
    "orbit_show": "0e14370d0923102c610000000d041b0d03190d0319110421400e7d0d03190d0319102e65000000390c6e2408450d031a0d03190d041b300d5f0b0624040923000000040820040822080a2c040922040820",
    "gold_show": "6c44209b672ea0732d0000009d6f2da0742d9a6f2b9168299d702d9d6d2d724d216a2726000000533b1731230e603f1c7f2b2e261b0b191004794c0f6740140000002416060f0a03332108412b0c110a03",
    "prism_show": "5a3f9d7121a67121a6000000a23d12a23d12a66e22a66e22937330a66e22a66e22a66e2200000057449b268588a23d1274239ca23d12274b5d2c6456187a5500000054129c5c16a0a4380a4b136193310f",
    "profile_show": "1c405800000000000000000007203400000026455700000001091033627e000000010102000000051c2f0101020c1e2b01010201091000000000000000000000000001070c00010201101c063e481acf99",
    "branded_intro": "000000000000000000000000000000000000000000000000000000010e19010e19010e19000000010e19010e19152b3a74b8da071723192529192529685732000000192529685732192529685732192529",
    "sendoff": "310b60310b60310b60000000310b60310b60310b60310b60310b60010003010003010003000000010003010003010003010003010003000000000000000000000000000000000000000000000000000000",
    "landmark": "1d795b871551570e380000000902110902110902110902111144390b021209021116694f0000000902110902110b02126a11427512480902110a02127e144d0000000902110c021309031218765712463a",
]

// MARK: Animazioni adattive (porting di Effetti_Adattivi.py, valori di riferimento calcolati dal Python)
func AP(_ x: Double, _ y: Double, _ z: Double, _ zone: AdaptiveEffects.Zone) -> AdaptiveEffects.Point { AdaptiveEffects.Point(position: SIMD3(x, y, z), zone: zone) }
let adaptivePts: [Int: [Int: [AdaptiveEffects.Point]]] = [
    0: [0: [AP(1.95, 0.62, -0.4, .paraurti_anteriore)],
        1: [AP(1.40, 0.95, -0.3, .cofano), AP(1.40, 0.95, 0.3, .cofano)],
        2: [AP(0.90, 1.20, -0.62, .montante_anteriore), AP(-0.5, 1.43, 0.2, .tetto)],
        4: [AP(-0.10, 0.80, -0.86, .fiancata_anteriore)]],
    1: [0: [AP(-0.30, 1.10, 0.8, .montante_centrale)],
        1: [AP(-1.20, 0.55, 0.85, .fiancata_posteriore), AP(-1.25, 0.50, -0.85, .fiancata_posteriore)],
        2: [AP(-1.60, 1.15, 0.6, .montante_posteriore)],
        3: [AP(-1.98, 0.90, 0.1, .portellone)]],
]
let adaptiveEngine = AdaptiveEffects.Engine(addressCounts: [5, 4], points: adaptivePts)
var adaptiveExact = 0, adaptiveTotal = 0, adaptiveWorst = 0, adaptiveWorstID = ""
check(AdaptiveEffects.presets.count == 60 && Set(AdaptiveEffects.presets.map { $0.id }).count == 60, "adattivi: 60 preset distinti")
check(Set(adaptiveGolden.keys) == Set(AdaptiveEffects.presets.map { $0.id }), "adattivi: stessi preset del riferimento")
for p in AdaptiveEffects.presets {
    guard let hex = adaptiveGolden[p.id] else { continue }
    let ref: [UInt8] = stride(from: 0, to: hex.count, by: 2).map { i in
        let a = hex.index(hex.startIndex, offsetBy: i); return UInt8(hex[a..<hex.index(a, offsetBy: 2)], radix: 16)! }
    var mine: [UInt8] = []
    for t in [0.37, 2.9, 7.3] { for row in adaptiveEngine.frame(p, elapsed: t) { for c in row { mine += [c.r, c.g, c.b] } } }
    for (a, b) in zip(mine, ref) {
        adaptiveTotal += 1
        if a == b { adaptiveExact += 1 }
        let d = abs(Int(a) - Int(b)); if d > adaptiveWorst { adaptiveWorst = d; adaptiveWorstID = p.id }
    }
    if mine.count != ref.count { adaptiveWorst = 999; adaptiveWorstID = p.id + " (lunghezza)" }
}
check(adaptiveWorst <= 1 && Double(adaptiveExact) >= 0.99 * Double(adaptiveTotal), "adattivi: identici al riferimento Python",
      "\(adaptiveExact)/\(adaptiveTotal) esatti, scarto massimo \(adaptiveWorst) in \(adaptiveWorstID)")
// Test di accettazione della specifica
let waveP = AdaptiveEffects.preset("ignition_sweep")!
func firstLit(_ e: AdaptiveEffects.Engine, _ c: Int, _ k: Int) -> Double {
    for n in 0..<60 { let f = e.frame(waveP, elapsed: Double(n) / 24)[c][k]; if Int(f.r) + Int(f.g) + Int(f.b) > 300 { return Double(n) / 24 } }
    return -1
}
var moved = adaptivePts; moved[1]![1] = [AP(1.45, 0.92, -0.3, .cofano), AP(-1.25, 0.50, -0.85, .fiancata_posteriore)]
let tSide = firstLit(adaptiveEngine, 1, 1), tHood = firstLit(AdaptiveEffects.Engine(addressCounts: [5, 4], points: moved), 1, 1)
check(tSide >= 0 && tHood >= 0 && tHood < tSide, "adattivi: spostare un punto sul cofano anticipa l'onda", "\(tSide) → \(tHood)")
let hole = adaptiveEngine.frame(AdaptiveEffects.preset("aurora")!, elapsed: 1.3)
check(hole[0][3] == .black && hole[0].count == 5 && hole[0][4] != .black, "adattivi: indirizzo senza punti spento, i successivi mantengono l'indice")
check(AdaptiveEffects.pmod(-0.25, 1) == 0.75 && AdaptiveEffects.add(SIMD3(0.5, 1.5, 300)) == SIMD3(0, 2, 255), "adattivi: resto e arrotondamento come Python")

print("\n\(passed) superati, \(failures) falliti")
if let dir = CommandLine.arguments.dropFirst().first {
    try? "\(passed) superati, \(failures) falliti\n".write(toFile: dir + "/logic-summary.txt", atomically: true, encoding: .utf8)
}
exit(failures == 0 ? 0 : 1)
