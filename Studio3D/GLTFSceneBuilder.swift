import SceneKit
import UIKit

/// Converte un `GLTFModel.Model` (già nel sistema dell'app) in nodi SceneKit con materiali PBR.
enum GLTFSceneBuilder {
    private static var cache: [String: GLTFModel.Model] = [:]

    /// Carica (con cache per file e data di modifica) un .glb escludendo i nodi marcatore dei LED.
    static func model(at url: URL) throws -> GLTFModel.Model {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)"
        if let m = cache[key] { return m }
        let m = try GLTFModel.load(try Data(contentsOf: url, options: .mappedIfSafe), skipNode: CarModelFactory.isLEDMarker)
        cache = [key: m]
        return m
    }

    static func node(_ model: GLTFModel.Model) -> SCNNode {
        let root = SCNNode()
        var bodyMaterials = Set(model.parts.filter { isBody($0.name) }.compactMap { $0.material })
        for (i, m) in model.materials.enumerated() where isPaintMaterial(m.name) { bodyMaterials.insert(i) }
        let mats: [SCNMaterial] = model.materials.enumerated().map { i, m in material(m, body: bodyMaterials.contains(i)) }
        let fallback = SCNMaterial()
        fallback.lightingModel = .physicallyBased
        fallback.diffuse.contents = UIColor(white: 0.6, alpha: 1)
        for part in model.parts where !part.indices.isEmpty {
            // I SIMD3<Float> occupano 16 byte: SceneKit li legge direttamente con passo 16, senza copie intermedie.
            var sources = [source(part.positions, .vertex)]
            if part.normals.count == part.positions.count { sources.append(source(part.normals, .normal)) }
            let element = SCNGeometryElement(indices: part.indices, primitiveType: .triangles)
            let g = SCNGeometry(sources: sources, elements: [element])
            g.materials = [part.material.flatMap { mats[safe: $0] } ?? fallback]
            let n = SCNNode(geometry: g)
            n.name = part.name
            root.addChildNode(n)
        }
        return root
    }

    private static func source(_ v: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let data = v.withUnsafeBytes { Data($0) }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: v.count, usesFloatComponents: true,
                                 componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride)
    }

    /// Vernice della carrozzeria riconosciuta dal nome del materiale (es. "…_Python_Yellow" nel modello S-Line).
    private static func isPaintMaterial(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("python_yellow") || n.contains("carpaint") || n.contains("car_paint") || n.contains("paint") || n.contains("carrozz")
    }

    private static func isBody(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("carrozzeria") || n.contains("body") || n.contains("paint")
    }

    /// I fattori glTF sono lineari; UIColor è sRGB.
    private static func srgb(_ v: Float) -> CGFloat {
        let c = max(0, min(1, v))
        return CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }

    private static func material(_ m: GLTFModel.Material, body: Bool) -> SCNMaterial {
        let s = SCNMaterial()
        // "body:" fa sì che il colore carrozzeria scelto nell'app venga applicato a questo materiale.
        s.name = body ? "body: \(m.name)" : m.name
        s.lightingModel = .physicallyBased
        s.diffuse.contents = UIColor(red: srgb(m.baseColor.x), green: srgb(m.baseColor.y), blue: srgb(m.baseColor.z), alpha: 1)
        s.metalness.contents = NSNumber(value: m.metallic)
        s.roughness.contents = NSNumber(value: m.roughness)
        if m.emissive.x + m.emissive.y + m.emissive.z > 0 {
            s.emission.contents = UIColor(red: srgb(m.emissive.x), green: srgb(m.emissive.y), blue: srgb(m.emissive.z), alpha: 1)
            s.emission.intensity = CGFloat(min(max(m.emissiveStrength, 0), 8))
        }
        if m.clearcoat > 0 {
            s.clearCoat.contents = NSNumber(value: m.clearcoat)
            s.clearCoatRoughness.contents = NSNumber(value: m.clearcoatRoughness)
        }
        s.isDoubleSided = m.doubleSided
        if m.blend || m.baseColor.w < 0.999 {
            s.transparency = CGFloat(m.baseColor.w)
            s.blendMode = .alpha
            s.writesToDepthBuffer = false
        }
        return s
    }
}
