import Foundation

/// Pacchetto di animazioni pre-calcolate (es. "AudiLightStudio_Effetti.json"): per ogni preset una
/// sequenza di fotogrammi RGB8, fotogramma dopo fotogramma, centralina dopo centralina, un colore
/// per indirizzo (le due copie a Y ricevono lo stesso colore perché sono lo stesso indirizzo).
struct FramePack {
    struct Preset: Identifiable {
        let id: String
        let name: String
        let fps: Int
        let frameCount: Int
        let loop: Bool
        let frames: [UInt8]
        var duration: Double { Double(frameCount) / Double(fps) }
    }

    struct Settings: Equatable {
        var speed: Double = 1        // 0,5×…2×
        var intensity: Double = 1    // 0…1
        var tint: RGB? = nil         // colore unico che segue la luminosità originale

        var clamped: Settings {
            Settings(speed: speed.isFinite ? min(2, max(0.5, speed)) : 1,
                     intensity: intensity.isFinite ? min(1, max(0, intensity)) : 1,
                     tint: tint)
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case unreadable
        case format(String)
        case preset(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Pacchetto effetti non leggibile."
            case .format(let m): return "Pacchetto effetti non compatibile: \(m)."
            case .preset(let id): return "Preset \"\(id)\" danneggiato (dimensione dei fotogrammi errata)."
            }
        }
    }

    let controllerIDs: [String]
    let addressCounts: [Int]
    let presets: [Preset]
    var frameBytes: Int { addressCounts.reduce(0, +) * 3 }

    private struct File: Decodable {
        struct Controller: Decodable { let id: String; let address_count: Int }
        struct P: Decodable { let id: String; let name: String; let fps: Int; let frame_count: Int; let loop: Bool; let frames_b64: String }
        let schema_version: Int
        let pixel_format: String
        let packing: String
        let topology: String?
        let controller_order: [Controller]
        let presets: [P]
    }

    static func load(_ data: Data) throws -> FramePack {
        let f: File
        do { f = try JSONDecoder().decode(File.self, from: data) } catch { throw Failure.unreadable }
        guard f.schema_version == 1 else { throw Failure.format("versione \(f.schema_version)") }
        guard f.pixel_format == "RGB8" else { throw Failure.format("pixel \(f.pixel_format)") }
        guard f.packing == "frame_major_rgb" else { throw Failure.format("impaginazione \(f.packing)") }
        guard (1...8).contains(f.controller_order.count) else { throw Failure.format("\(f.controller_order.count) centraline") }
        guard f.controller_order.allSatisfy({ (1...IdealProtocol.maxSafeLEDs).contains($0.address_count) }) else {
            throw Failure.format("oltre \(IdealProtocol.maxSafeLEDs) indirizzi per centralina")
        }
        guard Set(f.presets.map { $0.id }).count == f.presets.count, !f.presets.isEmpty else { throw Failure.format("preset vuoti o ripetuti") }
        let bytes = f.controller_order.reduce(0) { $0 + $1.address_count } * 3
        var list: [Preset] = []
        for p in f.presets {
            guard (1...120).contains(p.fps), (1...100_000).contains(p.frame_count),
                  let raw = Data(base64Encoded: p.frames_b64), raw.count == p.frame_count * bytes
            else { throw Failure.preset(p.id) }
            list.append(Preset(id: p.id, name: p.name, fps: p.fps, frameCount: p.frame_count, loop: p.loop, frames: [UInt8](raw)))
        }
        return FramePack(controllerIDs: f.controller_order.map { $0.id }, addressCounts: f.controller_order.map { $0.address_count }, presets: list)
    }

    func preset(_ id: String) -> Preset? { presets.first { $0.id == id } }

    /// Fotogramma da mostrare dopo `position` secondi di animazione (già moltiplicati per la velocità).
    /// I preset in loop si ripetono; gli altri restano sull'ultimo fotogramma.
    static func frameIndex(_ p: Preset, position: Double) -> Int {
        guard position.isFinite, position > 0 else { return 0 }
        let t = p.loop ? position.truncatingRemainder(dividingBy: p.duration) : min(position, p.duration)
        return min(Int(t * Double(p.fps)), p.frameCount - 1)
    }

    /// Colori per centralina (nell'ordine del pacchetto) al fotogramma indicato.
    func colors(_ p: Preset, frame index: Int, settings: Settings = Settings()) -> [[RGB]] {
        let s = settings.clamped
        var offset = min(max(index, 0), p.frameCount - 1) * frameBytes
        var out: [[RGB]] = []
        for n in addressCounts {
            var row: [RGB] = []
            row.reserveCapacity(n)
            for _ in 0..<n {
                let r = p.frames[offset], g = p.frames[offset + 1], b = p.frames[offset + 2]
                offset += 3
                if let tint = s.tint {
                    let k = Double(max(r, g, b)) / 255 * s.intensity
                    row.append(RGB(r: UInt8((Double(tint.r) * k).rounded()), g: UInt8((Double(tint.g) * k).rounded()), b: UInt8((Double(tint.b) * k).rounded())))
                } else if s.intensity < 1 {
                    row.append(RGB(r: UInt8((Double(r) * s.intensity).rounded()), g: UInt8((Double(g) * s.intensity).rounded()), b: UInt8((Double(b) * s.intensity).rounded())))
                } else {
                    row.append(RGB(r: r, g: g, b: b))
                }
            }
            out.append(row)
        }
        return out
    }

    /// Intensità e colore unico applicati a un colore già calcolato.
    static func adjust(_ c: RGB, _ settings: Settings) -> RGB {
        let s = settings.clamped
        if let tint = s.tint {
            let k = Double(max(c.r, c.g, c.b)) / 255 * s.intensity
            return RGB(r: UInt8((Double(tint.r) * k).rounded()), g: UInt8((Double(tint.g) * k).rounded()), b: UInt8((Double(tint.b) * k).rounded()))
        }
        if s.intensity >= 1 { return c }
        return RGB(r: UInt8((Double(c.r) * s.intensity).rounded()), g: UInt8((Double(c.g) * s.intensity).rounded()), b: UInt8((Double(c.b) * s.intensity).rounded()))
    }

    /// Converte i colori per centralina del pacchetto in colori per pixel logico dell'app:
    /// la centralina n del pacchetto va alla n-esima centralina della lista (come il layout di progetto).
    static func keyed(_ rows: [[RGB]], controllers: [ControllerConfig]) -> [LEDKey: RGB] {
        let list = controllers.sorted { $0.order < $1.order }
        var out: [LEDKey: RGB] = [:]
        for (i, row) in rows.enumerated() where list.indices.contains(i) {
            for (p, c) in row.enumerated() where p < list[i].ledCount { out[LEDKey(controller: list[i].id, pixel: p)] = c }
        }
        return out
    }
}
