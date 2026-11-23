import Foundation
import simd

/// Lettore minimo di modelli glTF 2.0 binari (.glb): mesh triangolari, trasformazioni dei nodi e
/// materiali PBR a colore pieno (niente texture, skin, animazioni o compressione).
/// Tutto viene "cotto" nel sistema dell'app (x avanti, y alto, z destra) così la geometria
/// combacia con le posizioni dei LED dello stesso progetto senza scalature.
enum GLTFModel {
    struct Material: Equatable {
        var name: String
        var baseColor = SIMD4<Float>(0.8, 0.8, 0.8, 1)
        var metallic: Float = 0
        var roughness: Float = 0.5
        var emissive = SIMD3<Float>(0, 0, 0)
        var emissiveStrength: Float = 1
        var doubleSided = false
        var blend = false
        /// KHR_materials_clearcoat (vernice trasparente sopra il colore).
        var clearcoat: Float = 0
        var clearcoatRoughness: Float = 0
    }

    struct Part {
        var name: String
        var material: Int?
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var indices: [UInt32]
    }

    struct Model {
        var parts: [Part]
        var materials: [Material]
        var boundsMin: SIMD3<Float>
        var boundsMax: SIMD3<Float>
        var skippedNodes: Int
        var skippedPrimitives: Int
        var triangleCount: Int { parts.reduce(0) { $0 + $1.indices.count / 3 } }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case notGLB
        case corrupt(String)
        case unsupported(String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notGLB: return "Non è un file glTF binario (.glb)."
            case .corrupt(let m): return "File .glb danneggiato: \(m)"
            case .unsupported(let m): return "Funzione glTF non supportata: \(m)"
            case .tooLarge: return "Modello troppo pesante per l'anteprima (oltre 3 milioni di triangoli)."
            }
        }
    }

    static let maxTriangles = 3_000_000

    // MARK: Contenitore GLB

    static func split(_ data: Data) throws -> (json: Data, bin: [UInt8]) {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] == 0x67, b[1] == 0x6C, b[2] == 0x54, b[3] == 0x46 else { throw Failure.notGLB }
        guard u32(b, 4) == 2 else { throw Failure.unsupported("versione \(u32(b, 4))") }
        let total = min(Int(u32(b, 8)), b.count)
        var off = 12
        var json: Data?
        var bin: [UInt8] = []
        while off + 8 <= total {
            let len = Int(u32(b, off)), type = u32(b, off + 4)
            let start = off + 8
            guard len >= 0, start + len <= total else { throw Failure.corrupt("blocco oltre la fine del file") }
            if type == 0x4E4F534A, json == nil { json = Data(b[start..<start + len]) }
            else if type == 0x004E4942, bin.isEmpty { bin = Array(b[start..<start + len]) }
            off = start + len
        }
        guard let json else { throw Failure.corrupt("manca il blocco JSON") }
        return (json, bin)
    }

    // MARK: Caricamento

    static func load(_ data: Data, frame: AxisFrame = AxisFrame(front: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), left: SIMD3(0, 0, -1)),
                     skipNode: (String) -> Bool = { _ in false }) throws -> Model {
        guard frame.isValid else { throw Failure.unsupported("assi") }
        let (jsonData, bin) = try split(data)
        let doc: Doc
        do { doc = try JSONDecoder().decode(Doc.self, from: jsonData) }
        catch { throw Failure.corrupt("JSON non valido") }
        let supported: Set<String> = ["KHR_materials_emissive_strength", "KHR_materials_clearcoat"]
        if let req = doc.extensionsRequired?.first(where: { !supported.contains($0) }) { throw Failure.unsupported(req) }
        if let bufs = doc.buffers, bufs.count > 1 || bufs.first?.uri != nil {
            throw Failure.unsupported("buffer esterni")
        }

        let nodes = doc.nodes ?? []
        let meshes = doc.meshes ?? []
        let reader = Reader(doc: doc, bin: bin)

        // Matrice file → app (righe: avanti, alto, destra = −sinistra).
        let c = simd_double3x3(rows: [frame.front, frame.up, -frame.left])

        let roots: [Int]
        if let scenes = doc.scenes, !scenes.isEmpty {
            roots = scenes[min(max(doc.scene ?? 0, 0), scenes.count - 1)].nodes ?? []
        } else {
            let children = Set(nodes.flatMap { $0.children ?? [] })
            roots = nodes.indices.filter { !children.contains($0) }
        }

        var parts: [Part] = []
        var skippedNodes = 0, skippedPrims = 0, triangles = 0
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var visited = Set<Int>()

        func visit(_ i: Int, _ parent: simd_double4x4, depth: Int) throws {
            guard nodes.indices.contains(i), depth < 64, visited.insert(i).inserted else { return }
            let n = nodes[i]
            let name = n.name ?? "node\(i)"
            if skipNode(name) { skippedNodes += 1; return }
            let m = parent * n.localMatrix
            if let mi = n.mesh, meshes.indices.contains(mi) {
                let m3 = simd_double3x3(columns: (SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                                  SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                                  SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
                let t = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                let lin = c * m3
                let det = lin.determinant
                let normalMat = abs(det) > 1e-12 ? lin.inverse.transpose : lin
                let flip = det < 0
                for (pi, prim) in meshes[mi].primitives.enumerated() {
                    guard (prim.mode ?? 4) == 4, let pa = prim.attributes["POSITION"] else { skippedPrims += 1; continue }
                    let raw = try reader.vec3(pa)
                    let rawN = try prim.attributes["NORMAL"].map { try reader.vec3($0) }
                    var idx: [UInt32] = try prim.indices.map { try reader.indices($0) } ?? (0..<UInt32(raw.count)).map { $0 }
                    idx = Array(idx.prefix(idx.count - idx.count % 3))
                    guard idx.allSatisfy({ Int($0) < raw.count }) else { throw Failure.corrupt("indici fuori intervallo") }
                    triangles += idx.count / 3
                    if triangles > maxTriangles { throw Failure.tooLarge }
                    if flip {
                        var k = 0
                        while k + 2 < idx.count { idx.swapAt(k + 1, k + 2); k += 3 }
                    }
                    let pos: [SIMD3<Float>] = raw.map { p in
                        let w = lin * SIMD3<Double>(p) + c * t
                        return SIMD3<Float>(w)
                    }
                    for p in pos { lo = simd_min(lo, p); hi = simd_max(hi, p) }
                    let nor: [SIMD3<Float>] = rawN.map { list in list.map { v in
                        let w = normalMat * SIMD3<Double>(v)
                        let l = simd_length(w)
                        return l > 0 ? SIMD3<Float>(w / l) : SIMD3<Float>(0, 1, 0)
                    } } ?? []
                    let partName = (meshes[mi].primitives.count > 1 ? "\(name).\(pi)" : name)
                    parts.append(Part(name: partName, material: prim.material, positions: pos,
                                      normals: nor.count == pos.count ? nor : [], indices: idx))
                }
            }
            for ch in n.children ?? [] { try visit(ch, m, depth: depth + 1) }
        }
        for r in roots { try visit(r, matrix_identity_double4x4, depth: 0) }

        let materials: [Material] = (doc.materials ?? []).enumerated().map { (i, mt) in
            var out = Material(name: mt.name ?? "material\(i)")
            if let f = mt.pbrMetallicRoughness?.baseColorFactor, f.count == 4 { out.baseColor = SIMD4<Float>(f.map { Float($0) }) }
            if let v = mt.pbrMetallicRoughness?.metallicFactor { out.metallic = Float(v) } else { out.metallic = 1 }
            if let v = mt.pbrMetallicRoughness?.roughnessFactor { out.roughness = Float(v) } else { out.roughness = 1 }
            if let e = mt.emissiveFactor, e.count == 3 { out.emissive = SIMD3<Float>(e.map { Float($0) }) }
            if let s = mt.extensions?.KHR_materials_emissive_strength?.emissiveStrength { out.emissiveStrength = Float(s) }
            if let cc = mt.extensions?.KHR_materials_clearcoat {
                out.clearcoat = Float(min(max(cc.clearcoatFactor ?? 0, 0), 1))
                out.clearcoatRoughness = Float(min(max(cc.clearcoatRoughnessFactor ?? 0, 0), 1))
            }
            out.doubleSided = mt.doubleSided ?? false
            out.blend = (mt.alphaMode ?? "OPAQUE") == "BLEND"
            return out
        }
        if parts.isEmpty { lo = .zero; hi = .zero }
        return Model(parts: parts, materials: materials, boundsMin: lo, boundsMax: hi,
                     skippedNodes: skippedNodes, skippedPrimitives: skippedPrims)
    }

    // MARK: Lettura accessor

    private struct Reader {
        let doc: Doc
        let bin: [UInt8]

        func layout(_ a: Int, comps: Int) throws -> (acc: Doc.Accessor, base: Int, stride: Int, size: Int) {
            guard let acc = doc.accessors?[safe: a] else { throw Failure.corrupt("accessor \(a) mancante") }
            if acc.sparse != nil { throw Failure.unsupported("accessor sparse") }
            guard let bvi = acc.bufferView, let bv = doc.bufferViews?[safe: bvi] else { throw Failure.corrupt("bufferView mancante") }
            let size: Int
            switch acc.componentType {
            case 5120, 5121: size = 1
            case 5122, 5123: size = 2
            case 5125, 5126: size = 4
            default: throw Failure.unsupported("componentType \(acc.componentType)")
            }
            let elem = size * comps
            let stride = bv.byteStride ?? elem
            let base = (bv.byteOffset ?? 0) + (acc.byteOffset ?? 0)
            guard acc.count >= 0, stride >= elem else { throw Failure.corrupt("accessor \(a)") }
            if acc.count > 0 {
                let end = base + (acc.count - 1) * stride + elem
                guard base >= 0, end <= (bv.byteOffset ?? 0) + bv.byteLength, end <= bin.count else { throw Failure.corrupt("dati oltre il buffer") }
            }
            return (acc, base, stride, size)
        }

        func vec3(_ a: Int) throws -> [SIMD3<Float>] {
            let l = try layout(a, comps: 3)
            guard l.acc.type == "VEC3", l.acc.componentType == 5126 else { throw Failure.unsupported("posizioni/normali non float") }
            var out: [SIMD3<Float>] = []
            out.reserveCapacity(l.acc.count)
            for i in 0..<l.acc.count {
                let o = l.base + i * l.stride
                out.append(SIMD3(f32(bin, o), f32(bin, o + 4), f32(bin, o + 8)))
            }
            guard out.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw Failure.corrupt("coordinate non valide") }
            return out
        }

        func indices(_ a: Int) throws -> [UInt32] {
            let l = try layout(a, comps: 1)
            guard l.acc.type == "SCALAR" else { throw Failure.corrupt("indici") }
            var out: [UInt32] = []
            out.reserveCapacity(l.acc.count)
            for i in 0..<l.acc.count {
                let o = l.base + i * l.stride
                switch l.acc.componentType {
                case 5121: out.append(UInt32(bin[o]))
                case 5123: out.append(UInt32(bin[o]) | UInt32(bin[o + 1]) << 8)
                case 5125: out.append(u32(bin, o))
                default: throw Failure.unsupported("indici di tipo \(l.acc.componentType)")
                }
            }
            return out
        }
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func f32(_ b: [UInt8], _ o: Int) -> Float { Float(bitPattern: u32(b, o)) }

    // MARK: Sottoinsieme dello schema glTF

    struct Doc: Decodable {
        struct Node: Decodable {
            var name: String?
            var mesh: Int?
            var children: [Int]?
            var matrix: [Double]?
            var translation: [Double]?
            var rotation: [Double]?
            var scale: [Double]?

            var localMatrix: simd_double4x4 {
                if let m = matrix, m.count == 16 {
                    return simd_double4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                                    SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
                }
                let t = translation?.count == 3 ? translation! : [0, 0, 0]
                let q = rotation?.count == 4 ? rotation! : [0, 0, 0, 1]
                let s = scale?.count == 3 ? scale! : [1, 1, 1]
                let (x, y, z, w) = (q[0], q[1], q[2], q[3])
                let r = simd_double3x3(rows: [
                    SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)),
                    SIMD3(2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)),
                    SIMD3(2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)),
                ])
                let c0 = r.columns.0 * s[0], c1 = r.columns.1 * s[1], c2 = r.columns.2 * s[2]
                return simd_double4x4(columns: (SIMD4(c0, 0), SIMD4(c1, 0), SIMD4(c2, 0), SIMD4(t[0], t[1], t[2], 1)))
            }
        }
        struct Primitive: Decodable {
            var attributes: [String: Int]
            var indices: Int?
            var material: Int?
            var mode: Int?
        }
        struct Mesh: Decodable {
            var name: String?
            var primitives: [Primitive]
        }
        struct Sparse: Decodable { var count: Int? }
        struct Accessor: Decodable {
            var bufferView: Int?
            var byteOffset: Int?
            var componentType: Int
            var count: Int
            var type: String
            var sparse: Sparse?
        }
        struct BufferView: Decodable {
            var buffer: Int
            var byteOffset: Int?
            var byteLength: Int
            var byteStride: Int?
        }
        struct Buffer: Decodable {
            var byteLength: Int
            var uri: String?
        }
        struct PBR: Decodable {
            var baseColorFactor: [Double]?
            var metallicFactor: Double?
            var roughnessFactor: Double?
        }
        struct Strength: Decodable { var emissiveStrength: Double? }
        struct Clearcoat: Decodable { var clearcoatFactor: Double?; var clearcoatRoughnessFactor: Double? }
        struct Extensions: Decodable { var KHR_materials_emissive_strength: Strength?; var KHR_materials_clearcoat: Clearcoat? }
        struct Mat: Decodable {
            var name: String?
            var pbrMetallicRoughness: PBR?
            var emissiveFactor: [Double]?
            var alphaMode: String?
            var doubleSided: Bool?
            var extensions: Extensions?
        }
        struct Scene: Decodable { var nodes: [Int]? }

        var scene: Int?
        var scenes: [Scene]?
        var nodes: [Node]?
        var meshes: [Mesh]?
        var accessors: [Accessor]?
        var bufferViews: [BufferView]?
        var buffers: [Buffer]?
        var materials: [Mat]?
        var extensionsRequired: [String]?
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
