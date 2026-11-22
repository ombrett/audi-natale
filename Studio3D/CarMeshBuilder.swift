import SceneKit
import UIKit
import simd

/// Modello provvisorio dell'auto costruito per sezioni da `CarShape` (superficie continua con normali
/// morbide, vetri, cerchi, fari). Non è il modello ufficiale dell'Audi A1.
enum CarMeshBuilder {
    static func makeCar(color: UIColor) -> SCNNode {
        let root = SCNNode()
        root.name = "car"
        let paint = paintMaterial(color)
        let glass = SCNMaterial()
        glass.name = "glass"
        glass.lightingModel = .physicallyBased
        glass.diffuse.contents = UIColor(red: 0.02, green: 0.025, blue: 0.035, alpha: 1)
        glass.metalness.contents = 0.95
        glass.roughness.contents = 0.06
        glass.isDoubleSided = true
        let under = SCNMaterial()
        under.lightingModel = .physicallyBased
        under.diffuse.contents = UIColor(white: 0.04, alpha: 1)
        under.roughness.contents = 0.9
        under.isDoubleSided = true

        root.addChildNode(SCNNode(geometry: body(paint: paint, glass: glass, under: under)))
        for axle in [CarShape.frontAxle, CarShape.rearAxle] {
            for side in [1.0, -1.0] { root.addChildNode(wheel(x: axle, side: side)) }
        }
        addLights(to: root)
        addDetails(to: root, paint: paint)
        return root
    }

    static func paintMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = "paint"
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 0.55
        m.roughness.contents = 0.28
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.05
        m.isDoubleSided = true
        return m
    }

    // MARK: Scocca

    private static func body(paint: SCNMaterial, glass: SCNMaterial, under: SCNMaterial) -> SCNGeometry {
        let xs = CarShape.stations
        let halves = xs.map { CarShape.halfSection($0) }
        let h = halves[0].count
        let n = 2 * h - 2
        func halfIndex(_ i: Int) -> Int { i < h ? i : 2 * h - 2 - i }

        // Griglia di vertici: sezione per sezione, anello chiuso (sinistra poi destra specchiata).
        var grid: [SIMD3<Float>] = []
        grid.reserveCapacity(xs.count * n)
        for (s, x) in xs.enumerated() {
            for i in 0..<n {
                let p = halves[s][halfIndex(i)]
                let z = i < h ? p.z : -p.z
                grid.append(SIMD3(Float(x), Float(p.y), Float(z)))
            }
        }
        func v(_ s: Int, _ i: Int) -> SIMD3<Float> { grid[s * n + ((i % n) + n) % n] }
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(grid.count)
        for s in 0..<xs.count {
            for i in 0..<n {
                let along = v(min(s + 1, xs.count - 1), i) - v(max(s - 1, 0), i)
                let around = v(s, i + 1) - v(s, i - 1)
                var nrm = simd_normalize(simd_cross(around, along))
                let p = v(s, i)
                if simd_dot(nrm, p - SIMD3(p.x, 0.75, 0)) < 0 { nrm = -nrm }
                if !nrm.x.isFinite { nrm = SIMD3(0, 1, 0) }
                normals.append(nrm)
            }
        }
        var paintIdx: [Int32] = [], glassIdx: [Int32] = [], underIdx: [Int32] = []
        for s in 0..<(xs.count - 1) {
            for i in 0..<n {
                let j = (i + 1) % n
                let a = halfIndex(i), b = halfIndex(j)
                let panel = halves[s][max(a, b)].panel
                let q: [Int32] = [Int32(s * n + i), Int32(s * n + j), Int32((s + 1) * n + j), Int32((s + 1) * n + i)]
                let tris = [q[0], q[1], q[2], q[0], q[2], q[3]]
                switch panel {
                case .window: glassIdx += tris
                case .underside: underIdx += tris
                default: paintIdx += tris
                }
            }
        }
        // Tappi anteriore e posteriore (ventaglio dal centro della sezione).
        var positions = grid
        for (s, dir) in [(0, Float(-1)), (xs.count - 1, Float(1))] {
            var c = SIMD3<Float>(0, 0, 0)
            for i in 0..<n { c += v(s, i) }
            c /= Float(n)
            let base = Int32(positions.count)
            positions.append(c)
            normals.append(SIMD3(dir, 0, 0))
            for i in 0..<n {
                positions.append(v(s, i))
                normals.append(SIMD3(dir, 0, 0))
            }
            for i in 0..<n {
                let a = base + 1 + Int32(i), b = base + 1 + Int32((i + 1) % n)
                paintIdx += [base, a, b]
            }
        }
        let vs = SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) })
        let ns = SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
        let elements = [paintIdx, glassIdx, underIdx].map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
        let g = SCNGeometry(sources: [vs, ns], elements: elements)
        g.materials = [paint, glass, under]
        return g
    }

    // MARK: Ruote

    private static func wheel(x: Double, side: Double) -> SCNNode {
        let node = SCNNode()
        let rubber = SCNMaterial()
        rubber.lightingModel = .physicallyBased
        rubber.diffuse.contents = UIColor(white: 0.03, alpha: 1)
        rubber.roughness.contents = 0.85
        let rimM = SCNMaterial()
        rimM.lightingModel = .physicallyBased
        rimM.diffuse.contents = UIColor(white: 0.75, alpha: 1)
        rimM.metalness.contents = 1
        rimM.roughness.contents = 0.25
        let darkM = SCNMaterial()
        darkM.diffuse.contents = UIColor(white: 0.08, alpha: 1)

        let tyre = SCNTube(innerRadius: 0.19, outerRadius: CGFloat(CarShape.wheelRadius), height: 0.205)
        tyre.radialSegmentCount = 48
        tyre.materials = [rubber]
        node.addChildNode(SCNNode(geometry: tyre))
        let disc = SCNCylinder(radius: 0.19, height: 0.17)
        disc.radialSegmentCount = 48
        disc.materials = [darkM]
        node.addChildNode(SCNNode(geometry: disc))
        // Cerchio a 5 razze doppie.
        let hub = SCNCylinder(radius: 0.045, height: 0.2)
        hub.materials = [rimM]
        node.addChildNode(SCNNode(geometry: hub))
        let ring = SCNTube(innerRadius: 0.17, outerRadius: 0.195, height: 0.19)
        ring.radialSegmentCount = 48
        ring.materials = [rimM]
        node.addChildNode(SCNNode(geometry: ring))
        for k in 0..<10 {
            let spoke = SCNBox(width: 0.022, height: 0.15, length: 0.03, chamferRadius: 0.006)
            spoke.materials = [rimM]
            let sn = SCNNode(geometry: spoke)
            let a = Float(k) / 10 * 2 * .pi + (k % 2 == 0 ? 0.06 : -0.06)
            sn.position = SCNVector3(0.1 * cos(a), 0.06 * Float(side), 0.1 * sin(a))
            // Prima z (asse lungo del box da y a −x), poi y: il box punta lungo (cos a, 0, sin a).
            sn.eulerAngles = SCNVector3(0, .pi - a, .pi / 2)
            node.addChildNode(sn)
        }
        // Asse del cilindro (y) ruotato verso z.
        node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        let z = (CarShape.beltHalfWidth * CarShape.taper(x) - 0.13) * side
        node.position = SCNVector3(Float(x), Float(CarShape.wheelRadius), Float(z))
        return node
    }

    // MARK: Luci e dettagli

    private static func addLights(to root: SCNNode) {
        let head = SCNMaterial()
        head.lightingModel = .constant
        head.diffuse.contents = UIColor(white: 0.95, alpha: 1)
        head.emission.contents = UIColor(white: 1, alpha: 1)
        let tail = SCNMaterial()
        tail.lightingModel = .constant
        tail.diffuse.contents = UIColor(red: 0.85, green: 0.02, blue: 0.05, alpha: 1)
        tail.emission.contents = UIColor(red: 0.9, green: 0.02, blue: 0.06, alpha: 1)
        for side: Float in [1, -1] {
            // Fari anteriori sottili, inclinati verso l'esterno.
            let h = SCNBox(width: 0.16, height: 0.06, length: 0.34, chamferRadius: 0.025)
            h.materials = [head]
            let hn = SCNNode(geometry: h)
            hn.position = SCNVector3(1.90, 0.735, 0.52 * side)
            hn.eulerAngles = SCNVector3(0, 0.45 * side, -0.35)
            root.addChildNode(hn)
            // Luci posteriori alte sui fianchi del portellone.
            let t = SCNBox(width: 0.12, height: 0.07, length: 0.30, chamferRadius: 0.02)
            t.materials = [tail]
            let tn = SCNNode(geometry: t)
            tn.position = SCNVector3(-1.955, 1.0, 0.56 * side)
            tn.eulerAngles = SCNVector3(0, -0.35 * side, 0.25)
            root.addChildNode(tn)
        }
    }

    private static func addDetails(to root: SCNNode, paint: SCNMaterial) {
        let black = SCNMaterial()
        black.lightingModel = .physicallyBased
        black.diffuse.contents = UIColor(white: 0.02, alpha: 1)
        black.roughness.contents = 0.4
        black.metalness.contents = 0.3
        // Calandra ottagonale (forma generica, senza loghi).
        let path = UIBezierPath()
        let w: CGFloat = 0.36, top: CGFloat = 0.13, bottom: CGFloat = 0.15
        path.move(to: CGPoint(x: -w * 0.8, y: top))
        path.addLine(to: CGPoint(x: w * 0.8, y: top))
        path.addLine(to: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w * 0.82, y: -bottom))
        path.addLine(to: CGPoint(x: -w * 0.82, y: -bottom))
        path.addLine(to: CGPoint(x: -w, y: 0))
        path.close()
        let grille = SCNShape(path: path, extrusionDepth: 0.06)
        grille.chamferRadius = 0.01
        grille.materials = [black]
        let gn = SCNNode(geometry: grille)
        gn.position = SCNVector3(1.985, 0.50, 0)
        gn.eulerAngles = SCNVector3(0, Float.pi / 2, 0)
        root.addChildNode(gn)
        // Specchietti.
        for side: Float in [1, -1] {
            let m = SCNBox(width: 0.14, height: 0.1, length: 0.18, chamferRadius: 0.04)
            m.materials = [paint]
            let mn = SCNNode(geometry: m)
            mn.position = SCNVector3(0.80, 1.0, 0.93 * side)
            root.addChildNode(mn)
        }
    }

    /// Ambiente di luce per i riflessi PBR (cielo chiaro sopra, pavimento scuro sotto).
    static func environmentImage() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0.85, alpha: 1).cgColor, UIColor(white: 0.35, alpha: 1).cgColor,
                          UIColor(white: 0.08, alpha: 1).cgColor, UIColor(white: 0.03, alpha: 1).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 0.55, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
    }
}
