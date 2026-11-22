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
    /// Parte dell'auto indicata dal layout di progetto (es. "tetto", "cofano"); nil per i LED scansionati.
    var part: String? = nil
    /// Ramo della Y ("left"/"right") indicato dal layout di progetto.
    var branch: String? = nil
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
    /// "design" = posizioni prese dal file di progetto (Blender), non misurate sull'auto.
    var source: String? = nil
    /// Esito dell'ultimo allineamento automatico al progetto (da mostrare all'utente).
    var alignmentInfo: String? = nil

    var isDesign: Bool { source == "design" }
    /// Vero solo per le mappe ottenute dalla scansione (né dimostrative né da progetto).
    var isMeasured: Bool { !isDemo && !isDesign }

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

/// Disposizione dimostrativa per provare l'interfaccia prima della scansione, ispirata allo schema
/// "4 pacchi da 2 × 20 m": ogni centralina riempie una zona con un percorso a zig-zag; le due file a Y
/// di ogni pacco stanno sulle due metà simmetriche (sinistra/destra). Sempre etichettata come dimostrativa.
enum DemoLayout {
    enum Region: CaseIterable { case roof, hood, sides, rear, sills }

    static func make(controllers: [ControllerConfig]) -> CarMap {
        let list = controllers.filter { $0.enabled }.sorted { $0.order < $1.order }
        var leds: [PhysicalLED] = []
        for (k, c) in list.enumerated() {
            let region = Region.allCases[k % Region.allCases.count]
            let count = min(c.ledCount, IdealProtocol.maxSafeLEDs)
            let path = resample(rows(region), count: count)
            for (i, p) in path.enumerated() {
                let key = LEDKey(controller: c.id, pixel: i)
                leds.append(PhysicalLED(key: key, world: p, confidence: 1, views: 0))
                if c.copiesPerPixel > 1 {
                    leds.append(PhysicalLED(key: key, world: SIMD3(p.x, p.y, -p.z), confidence: 1, views: 0))
                }
            }
        }
        var map = CarMap(name: "Mappa dimostrativa", leds: leds)
        map.isDemo = true
        return map
    }

    /// Righe del zig-zag su una metà (z > 0, lato destro) della zona; l'altra copia a Y è specchiata.
    static func rows(_ r: Region) -> [[SIMD3<Double>]] {
        func line(_ n: Int, _ f: (Double) -> SIMD3<Double>) -> [SIMD3<Double>] { (0...n).map { f(Double($0) / Double(n)) } }
        switch r {
        case .roof:
            return stride(from: -1.60, through: 0.05, by: 0.11).map { x in
                line(10) { t in let z = 0.06 + t * 0.48; return SIMD3(x, CarShape.topSurfaceY(x: x, z: z) + 0.01, z) }
            }
        case .hood:
            return stride(from: 1.05, through: 1.85, by: 0.08).map { x in
                line(10) { t in
                    let w = CarShape.hoodHalfWidth * CarShape.taper(x) * 0.92
                    let z = 0.06 + t * (w - 0.06)
                    return SIMD3(x, CarShape.topSurfaceY(x: x, z: z) + 0.01, z)
                }
            }
        case .sides:
            return stride(from: 0.42, through: 0.86, by: 0.065).map { y in
                line(24) { t in
                    let x = -1.40 + t * 2.20
                    let yy = min(y, CarShape.beltY(x) - 0.04)
                    return SIMD3(x, yy, CarShape.halfWidth(x: x, y: yy) + 0.012)
                }
            }
        case .rear:
            return stride(from: 0.45, through: 1.25, by: 0.07).map { y in
                line(10) { t in let z = 0.05 + t * 0.62; return SIMD3(rearSurfaceX(y) - 0.012, y, min(z, CarShape.halfWidth(x: rearSurfaceX(y), y: y) * 0.95)) }
            }
        case .sills:
            return [line(30) { t in
                let x = -1.75 + t * 3.5
                let y = max(CarShape.bottomY(x), 0.28) + 0.04
                return SIMD3(x, y, CarShape.halfWidth(x: x, y: y) + 0.012)
            }]
        }
    }

    /// Punto più arretrato della carrozzeria all'altezza y (portellone e paraurti posteriore).
    static func rearSurfaceX(_ y: Double) -> Double {
        var x = -CarShape.halfLength
        while x < -1.4 && CarShape.topY(x) < y { x += 0.005 }
        return x
    }

    /// Unisce le righe a serpentina e distribuisce `count` punti a distanza uguale lungo il percorso.
    static func resample(_ rows: [[SIMD3<Double>]], count: Int) -> [SIMD3<Double>] {
        var path: [SIMD3<Double>] = []
        for (i, r) in rows.enumerated() { path += i % 2 == 0 ? r : r.reversed() }
        guard path.count > 1, count > 0 else { return Array(path.prefix(count)) }
        var cum: [Double] = [0]
        for i in 1..<path.count { cum.append(cum[i - 1] + simd_distance(path[i - 1], path[i])) }
        let total = cum.last ?? 0
        var out: [SIMD3<Double>] = []
        var j = 1
        for k in 0..<count {
            let target = count == 1 ? 0 : total * Double(k) / Double(count - 1)
            while j < path.count - 1 && cum[j] < target { j += 1 }
            let seg = max(cum[j] - cum[j - 1], 1e-9)
            let t = min(max((target - cum[j - 1]) / seg, 0), 1)
            out.append(path[j - 1] + (path[j] - path[j - 1]) * t)
        }
        return out
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
        useProjectModel = d.object(forKey: "useProjectModel") as? Bool ?? true
    }

    /// Modello 3D dell'A1 dal progetto Blender incluso nell'app (stesse coordinate del layout LED).
    static var projectModelURL: URL? { Bundle.main.url(forResource: "Audi_A1_LED1600", withExtension: "glb") }

    /// Usa il modello di progetto quando non c'è un modello importato (altrimenti il parametrico).
    @Published var useProjectModel: Bool { didSet { save() } }

    var importedURL: URL? {
        guard let f = modelFile else { return nil }
        let u = dir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var modelURL: URL? { importedURL ?? (useProjectModel ? Self.projectModelURL : nil) }

    var isProvisional: Bool { modelURL == nil }
    var isProjectModel: Bool { importedURL == nil && modelURL != nil }

    /// Copia il file scelto (USDZ/SCN) nella cartella dell'app.
    func importModel(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "usdz" : url.pathExtension.lowercased()
        if ext == "glb" {
            // Verifica subito che il file sia leggibile, così l'errore arriva all'utente.
            _ = try GLTFModel.load(try Data(contentsOf: url), skipNode: CarModelFactory.isLEDMarker)
        }
        let name = "car-model." + ext
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
        d.set(useProjectModel, forKey: "useProjectModel")
    }
}
