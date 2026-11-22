import Foundation

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

print("\n\(passed) superati, \(failures) falliti")
if let dir = CommandLine.arguments.dropFirst().first {
    try? "\(passed) superati, \(failures) falliti\n".write(toFile: dir + "/logic-summary.txt", atomically: true, encoding: .utf8)
}
exit(failures == 0 ? 0 : 1)
