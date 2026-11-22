import SceneKit
import UIKit
import simd

/// Nuvola di LED come un'unica geometria a punti con colore per vertice (efficiente con 1600+ LED).
enum LEDPointCloud {
    static func geometry(positions: [SIMD3<Float>], colors: [SIMD4<Float>], pointSize: CGFloat = 10) -> SCNGeometry {
        let n = positions.count
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let colData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let posSource = SCNGeometrySource(data: posData, semantic: .vertex, vectorCount: n, usesFloatComponents: true,
                                          componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                                          dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let colSource = SCNGeometrySource(data: colData, semantic: .color, vectorCount: n, usesFloatComponents: true,
                                          componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0,
                                          dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let indices = (0..<Int32(n)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 2.5
        element.maximumPointScreenSpaceRadius = pointSize
        let g = SCNGeometry(sources: [posSource, colSource], elements: [element])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.readsFromDepthBuffer = true
        g.materials = [m]
        return g
    }

    static func color(_ c: RGB, alpha: Float = 1, boost: Bool = true) -> SIMD4<Float> {
        // I LED spenti restano visibili come puntini scuri; quelli accesi saturano un po' per sembrare luce.
        if c == .black { return SIMD4(0.16, 0.17, 0.19, alpha) }
        let k: Float = boost ? 1.25 : 1
        return SIMD4(min(1, Float(c.r) / 255 * k), min(1, Float(c.g) / 255 * k), min(1, Float(c.b) / 255 * k), alpha)
    }
}

/// Modello dell'auto: provvisorio (forme semplici con le dimensioni dell'Audi A1 Sportback 2020)
/// oppure un file USDZ/SCN importato dall'utente.
enum CarModelFactory {
    static func provisional(color: UIColor) -> SCNNode {
        let root = SCNNode()
        root.name = "car"
        let L = CGFloat(CarDimensions.length), W = CGFloat(CarDimensions.width), H = CGFloat(CarDimensions.height)
        let paint = SCNMaterial()
        paint.name = "paint"
        paint.lightingModel = .physicallyBased
        paint.diffuse.contents = color
        paint.metalness.contents = 0.6
        paint.roughness.contents = 0.35
        let glass = SCNMaterial()
        glass.lightingModel = .physicallyBased
        glass.diffuse.contents = UIColor(white: 0.05, alpha: 1)
        glass.metalness.contents = 0.9
        glass.roughness.contents = 0.1
        let rubber = SCNMaterial()
        rubber.diffuse.contents = UIColor(white: 0.08, alpha: 1)

        let lower = SCNBox(width: L, height: H * 0.47, length: W, chamferRadius: 0.18)
        lower.materials = [paint]
        let lowerNode = SCNNode(geometry: lower)
        lowerNode.position = SCNVector3(0, Float(0.18 + H * 0.47 / 2), 0)
        root.addChildNode(lowerNode)

        let cabin = SCNBox(width: L * 0.56, height: H * 0.36, length: W * 0.86, chamferRadius: 0.22)
        cabin.materials = [glass]
        let cabinNode = SCNNode(geometry: cabin)
        cabinNode.position = SCNVector3(Float(-L * 0.06), Float(0.18 + H * 0.47 + H * 0.36 / 2 - 0.04), 0)
        root.addChildNode(cabinNode)

        let roof = SCNBox(width: L * 0.5, height: 0.04, length: W * 0.8, chamferRadius: 0.02)
        roof.materials = [paint]
        let roofNode = SCNNode(geometry: roof)
        roofNode.position = SCNVector3(Float(-L * 0.07), Float(H - 0.02), 0)
        root.addChildNode(roofNode)

        for (x, z) in [(1.28, 0.76), (1.28, -0.76), (-1.28, 0.76), (-1.28, -0.76)] {
            let tyre = SCNCylinder(radius: 0.32, height: 0.22)
            tyre.materials = [rubber]
            let n = SCNNode(geometry: tyre)
            n.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            n.position = SCNVector3(Float(x), 0.32, Float(z))
            root.addChildNode(n)
        }
        // Fari e luci posteriori stilizzati per riconoscere il verso.
        for (x, c) in [(Float(L / 2) + 0.005, UIColor.white), (-Float(L / 2) - 0.005, UIColor.red)] {
            for z: Float in [0.55, -0.55] {
                let lamp = SCNBox(width: 0.02, height: 0.08, length: 0.32, chamferRadius: 0.01)
                let m = SCNMaterial()
                m.emission.contents = c
                m.diffuse.contents = c
                lamp.materials = [m]
                let n = SCNNode(geometry: lamp)
                n.position = SCNVector3(x, 0.75, z)
                root.addChildNode(n)
            }
        }
        return root
    }

    /// Carica un modello importato, lo porta a lunghezza 4,03 m, centrato e appoggiato a terra.
    static func imported(url: URL, yawSteps: Int, color: UIColor?) -> SCNNode? {
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
        let container = SCNNode()
        for child in scene.rootNode.childNodes { container.addChildNode(child) }
        container.eulerAngles.y = Float(yawSteps % 4) * Float.pi / 2
        let wrapper = SCNNode()
        wrapper.name = "car"
        wrapper.addChildNode(container)
        let (minB, maxB) = wrapper.boundingBox
        let sizeX = maxB.x - minB.x, sizeZ = maxB.z - minB.z
        let longest = max(sizeX, sizeZ)
        guard longest > 0 else { return wrapper }
        let s = Float(CarDimensions.length) / longest
        container.scale = SCNVector3(s, s, s)
        let (a, b) = wrapper.boundingBox
        container.position = SCNVector3(-(a.x + b.x) / 2, -a.y, -(a.z + b.z) / 2)
        if let color { tint(wrapper, color) }
        return wrapper
    }

    /// Colora i materiali che sembrano vernice (nome con "paint", "body", "carrozzeria", "car_paint").
    @discardableResult
    static func tint(_ node: SCNNode, _ color: UIColor) -> Int {
        var count = 0
        node.enumerateHierarchy { n, _ in
            for m in n.geometry?.materials ?? [] {
                let name = (m.name ?? "").lowercased()
                if name == "paint" || name.contains("paint") || name.contains("body") || name.contains("carrozz") {
                    m.diffuse.contents = color
                    count += 1
                }
            }
        }
        return count
    }
}

/// Punti di vista predefiniti attorno all'auto.
enum CameraPreset: String, CaseIterable, Identifiable {
    case iso, front, rear, left, right, top
    var id: String { rawValue }
    var label: String {
        switch self {
        case .iso: return "3/4"
        case .front: return "Davanti"
        case .rear: return "Dietro"
        case .left: return "Sinistra"
        case .right: return "Destra"
        case .top: return "Alto"
        }
    }
    var position: SCNVector3 {
        switch self {
        case .iso: return SCNVector3(5.2, 3.0, 5.0)
        case .front: return SCNVector3(7, 1.2, 0)
        case .rear: return SCNVector3(-7, 1.2, 0)
        case .left: return SCNVector3(0, 1.2, 7)
        case .right: return SCNVector3(0, 1.2, -7)
        case .top: return SCNVector3(0.01, 9, 0)
        }
    }
}
