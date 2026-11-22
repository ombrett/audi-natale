import Foundation
import simd

/// LED fisico mappato in 3D. Più LED fisici possono avere la stessa chiave logica (cablaggio a Y).
struct PhysicalLED: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: LEDKey
    /// Posizione nel mondo della scansione AR (metri).
    var world: SIMD3<Double>
    var confidence: Double
    var views: Int
    var manual = false
}

/// Mappa 3D dell'impianto: LED fisici + allineamento al modello dell'auto.
struct CarMap: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var leds: [PhysicalLED]
    var alignment = CarAlignment()
    /// Osservazioni grezze conservate per poter aggiungere viste e ricalcolare.
    var observations: [LEDObservation] = []
    var viewCount = 0
    /// Mappa dimostrativa generata dall'app (non è la tua auto): sempre indicata come tale.
    var isDemo = false

    func carPosition(_ led: PhysicalLED) -> SIMD3<Double> { alignment.toCar(led.world) }

    var effectPoints: [EffectPoint] { leds.map { EffectPoint(key: $0.key, position: carPosition($0)) } }

    /// Gli altri LED fisici comandati dallo stesso pixel logico.
    func twins(of led: PhysicalLED) -> [PhysicalLED] { leds.filter { $0.key == led.key && $0.id != led.id } }

    func coverage(codebook: Codebook) -> (found: Int, total: Int, perController: [UUID: (Int, Int)]) {
        let keys = Set(leds.map { $0.key })
        var per: [UUID: (Int, Int)] = [:]
        for e in codebook.entries {
            let f = keys.filter { $0.controller == e.controller && $0.pixel < e.count }.count
            per[e.controller] = (f, e.count)
        }
        return (per.values.reduce(0) { $0 + $1.0 }, codebook.total, per)
    }

    func missing(codebook: Codebook) -> [LEDKey] {
        let keys = Set(leds.map { $0.key })
        var out: [LEDKey] = []
        for e in codebook.entries {
            for i in 0..<e.count where !keys.contains(LEDKey(controller: e.controller, pixel: i)) {
                out.append(LEDKey(controller: e.controller, pixel: i))
            }
        }
        return out
    }
}

final class CarMapStore: ObservableObject {
    @Published private(set) var maps: [CarMap] = []
    @Published var activeID: UUID? { didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: "activeCarMap") } }
    private let url: URL

    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent("carmaps.json")
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([CarMap].self, from: data) { maps = list }
        if let s = UserDefaults.standard.string(forKey: "activeCarMap"), let id = UUID(uuidString: s) { activeID = id }
        if activeID == nil || !maps.contains(where: { $0.id == activeID }) { activeID = maps.last?.id }
    }

    var active: CarMap? { maps.first { $0.id == activeID } }

    func save(_ map: CarMap) {
        if let i = maps.firstIndex(where: { $0.id == map.id }) { maps[i] = map } else { maps.append(map) }
        activeID = map.id
        persist()
    }

    func delete(_ id: UUID) {
        maps.removeAll { $0.id == id }
        if activeID == id { activeID = maps.last?.id }
        persist()
    }

    func exportJSON() throws -> URL {
        let out = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("car-map-\(PacketLog.fileStamp()).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(maps).write(to: file, options: .atomic)
        return file
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(maps) { try? data.write(to: url, options: .atomic) }
    }
}

/// Programmi effetti e playlist salvati.
struct Playlist: Codable, Identifiable, Equatable {
    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var programID: UUID
        var seconds: Double
    }
    var id = UUID()
    var name: String
    var items: [Item]
}

final class EffectLibrary: ObservableObject {
    @Published private(set) var programs: [EffectProgram] = []
    @Published private(set) var playlists: [Playlist] = []
    private let url: URL

    private struct Stored: Codable { var programs: [EffectProgram]; var playlists: [Playlist] }

    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent("effects.json")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            programs = s.programs
            playlists = s.playlists
        }
    }

    func save(_ p: EffectProgram) {
        if let i = programs.firstIndex(where: { $0.id == p.id }) { programs[i] = p } else { programs.append(p) }
        persist()
    }

    func deleteProgram(_ id: UUID) {
        programs.removeAll { $0.id == id }
        for i in playlists.indices { playlists[i].items.removeAll { $0.programID == id } }
        persist()
    }

    func save(_ pl: Playlist) {
        if let i = playlists.firstIndex(where: { $0.id == pl.id }) { playlists[i] = pl } else { playlists.append(pl) }
        persist()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        persist()
    }

    func program(_ id: UUID) -> EffectProgram? { programs.first { $0.id == id } }

    private func persist() {
        if let data = try? JSONEncoder().encode(Stored(programs: programs, playlists: playlists)) { try? data.write(to: url, options: .atomic) }
    }
}

/// Disposizione dimostrativa per provare l'interfaccia prima della scansione.
/// Ogni centralina occupa un tratto della fiancata, con la copia a Y sul lato opposto.
enum DemoLayout {
    static func make(controllers: [ControllerConfig]) -> CarMap {
        let list = controllers.filter { $0.enabled }.sorted { $0.order < $1.order }
        let n = max(list.count, 1)
        var leds: [PhysicalLED] = []
        let halfL = CarDimensions.length / 2 - 0.1
        for (k, c) in list.enumerated() {
            let count = min(c.ledCount, IdealProtocol.maxSafeLEDs)
            for i in 0..<count {
                let s = (Double(k) + Double(i) / Double(max(count, 1))) / Double(n)
                let x = halfL - s * 2 * halfL
                let y = 0.42 + 0.05 * sin(s * .pi * 2)
                let z = CarDimensions.width / 2 + 0.02
                leds.append(PhysicalLED(key: LEDKey(controller: c.id, pixel: i), world: SIMD3(x, y, z), confidence: 1, views: 0))
                if c.copiesPerPixel > 1 {
                    leds.append(PhysicalLED(key: LEDKey(controller: c.id, pixel: i), world: SIMD3(x, y, -z), confidence: 1, views: 0))
                }
            }
        }
        var map = CarMap(name: "Mappa dimostrativa", leds: leds)
        map.isDemo = true
        return map
    }
}

/// Modello 3D e colore della carrozzeria.
final class CarModelStore: ObservableObject {
    @Published var bodyColor: RGB { didSet { save() } }
    @Published private(set) var modelFile: String?
    @Published var yawSteps: Int { didSet { save() } }
    private let dir: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        if let data = d.data(forKey: "bodyColor"), let c = try? JSONDecoder().decode(RGB.self, from: data) { bodyColor = c }
        else { bodyColor = RGB(r: 38, g: 42, b: 50) }
        modelFile = d.string(forKey: "modelFile")
        yawSteps = d.integer(forKey: "modelYaw")
    }

    var modelURL: URL? {
        guard let f = modelFile else { return nil }
        let u = dir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var isProvisional: Bool { modelURL == nil }

    /// Copia il file scelto (USDZ/SCN) nella cartella dell'app.
    func importModel(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = "car-model." + (url.pathExtension.isEmpty ? "usdz" : url.pathExtension.lowercased())
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: url, to: dest)
        modelFile = name
        save()
    }

    func removeModel() {
        if let u = modelURL { try? FileManager.default.removeItem(at: u) }
        modelFile = nil
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(bodyColor), forKey: "bodyColor")
        d.set(modelFile, forKey: "modelFile")
        d.set(yawSteps, forKey: "modelYaw")
    }
}
