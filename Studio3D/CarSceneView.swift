import SwiftUI
import SceneKit
import simd

/// Contenuto da disegnare nella scena 3D.
struct CarSceneContent: Equatable {
    var points: [SIMD3<Float>] = []
    var colors: [SIMD4<Float>] = []
    var selected: Int?
    /// Copia dello stesso indirizzo sul ramo opposto della Y (anello vuoto).
    var twin: Int?
    var bodyColor: RGB = RGB(r: 40, g: 44, b: 52)
    var modelURL: URL?
    var modelYawSteps = 0
    var showCar = true
    var pointSize: CGFloat = 10
}

/// Vista SceneKit: modello dell'auto + LED come punti colorati. Rotazione e pinch-to-zoom
/// con il controllo camera di SceneKit; tocco su un LED → `onSelect(indice del punto)`.
struct CarSceneView: UIViewRepresentable {
    var content: CarSceneContent
    var camera: CameraPreset
    var cameraToken: Int
    var onSelect: ((Int?) -> Void)?
    /// Direzioni a schermo degli assi X, Y, Z (per il gizmo), aggiornate mentre si ruota.
    var onAxes: (([CGVector]) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(Theme.background)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.autoenablesDefaultLighting = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        view.delegate = context.coordinator
        view.rendersContinuously = false
        context.coordinator.onAxes = onAxes
        context.coordinator.view = view
        context.coordinator.apply(content, force: true)
        context.coordinator.move(to: camera, animated: false)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onAxes = onAxes
        context.coordinator.apply(content, force: false)
        if context.coordinator.cameraToken != cameraToken {
            context.coordinator.cameraToken = cameraToken
            context.coordinator.move(to: camera, animated: true)
        }
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        weak var view: SCNView?
        var onSelect: ((Int?) -> Void)?
        var onAxes: (([CGVector]) -> Void)?
        private var lastAxes: [CGVector] = []
        private var lastAxesTime: TimeInterval = 0
        private let twinNode = SCNNode()
        var cameraToken = 0
        private var carNode: SCNNode?
        private let ledNode = SCNNode()
        private let selectionNode = SCNNode()
        private var last = CarSceneContent()
        private var lastModelKey = ""

        override init() {
            super.init()
            let cam = SCNCamera()
            // Campo visivo orizzontale fisso: l'auto occupa la stessa larghezza anche quando
            // l'inspector riduce l'altezza della vista (stessa inquadratura alla chiusura).
            cam.projectionDirection = .horizontal
            cam.fieldOfView = 48
            cam.zNear = 0.05
            cam.zFar = 100
            cam.wantsHDR = true
            // Alone minimo: i LED restano leggibili senza bagliori decorativi.
            cam.bloomIntensity = 0.35
            cam.bloomThreshold = 0.85
            cam.bloomBlurRadius = 3
            cameraNode.camera = cam
            scene.rootNode.addChildNode(cameraNode)

            scene.lightingEnvironment.contents = CarMeshBuilder.environmentImage()
            scene.lightingEnvironment.intensity = 1.2
            let floor = SCNFloor()
            floor.reflectivity = 0.03
            floor.reflectionFalloffEnd = 1.2
            let fm = SCNMaterial()
            fm.lightingModel = .constant
            fm.diffuse.contents = Coordinator.gridImage()
            fm.diffuse.wrapS = .repeat
            fm.diffuse.wrapT = .repeat
            fm.diffuse.contentsTransform = SCNMatrix4MakeScale(36, 36, 1)   // griglia fitta e discreta
            floor.materials = [fm]
            scene.rootNode.addChildNode(SCNNode(geometry: floor))

            let key = SCNLight(); key.type = .directional; key.intensity = 1100; key.castsShadow = true
            key.shadowMode = .deferred; key.shadowSampleCount = 8; key.shadowRadius = 6; key.shadowColor = UIColor(white: 0, alpha: 0.6)
            let keyNode = SCNNode(); keyNode.light = key; keyNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
            scene.rootNode.addChildNode(keyNode)
            let amb = SCNLight(); amb.type = .ambient; amb.intensity = 150
            let ambNode = SCNNode(); ambNode.light = amb
            scene.rootNode.addChildNode(ambNode)

            scene.rootNode.addChildNode(ledNode)
            // Punto toccato: cerchio pieno; copia sul ramo opposto: anello vuoto. Sempre rivolti alla camera.
            let mint = SCNMaterial(); mint.lightingModel = .constant; mint.diffuse.contents = UIColor(Theme.accent)
            mint.readsFromDepthBuffer = false
            let disc = SCNCylinder(radius: 0.028, height: 0.001); disc.materials = [mint]
            let discNode = SCNNode(geometry: disc); discNode.eulerAngles.x = .pi / 2
            let outer = SCNTorus(ringRadius: 0.045, pipeRadius: 0.005); outer.materials = [mint]
            let outerNode = SCNNode(geometry: outer); outerNode.eulerAngles.x = .pi / 2
            selectionNode.addChildNode(discNode)
            selectionNode.addChildNode(outerNode)
            let ring = SCNTorus(ringRadius: 0.04, pipeRadius: 0.005); ring.materials = [mint]
            let ringNode = SCNNode(geometry: ring); ringNode.eulerAngles.x = .pi / 2
            twinNode.addChildNode(ringNode)
            for n in [selectionNode, twinNode] {
                n.isHidden = true
                n.renderingOrder = 100
                n.constraints = [SCNBillboardConstraint()]
                scene.rootNode.addChildNode(n)
            }
        }

        /// Texture della griglia del pavimento (linee sottili su grafite).
        static func gridImage() -> UIImage {
            let size = CGSize(width: 64, height: 64)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor(Theme.background).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                UIColor(white: 1, alpha: 0.045).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 64))
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let onAxes, time - lastAxesTime > 0.05, let pov = renderer.pointOfView else { return }
            lastAxesTime = time
            let m = pov.presentation.simdWorldTransform
            let right = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
            let up = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
            let axes = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)].map {
                CGVector(dx: CGFloat(simd_dot($0, right)), dy: CGFloat(-simd_dot($0, up)))
            }
            let changed = zip(axes, lastAxes).contains { abs($0.dx - $1.dx) + abs($0.dy - $1.dy) > 0.01 } || lastAxes.isEmpty
            guard changed else { return }
            lastAxes = axes
            DispatchQueue.main.async { onAxes(axes) }
        }

        func apply(_ c: CarSceneContent, force: Bool) {
            let modelKey = "\(c.modelURL?.path ?? "provv")|\(c.modelYawSteps)|\(c.showCar)"
            if force || modelKey != lastModelKey {
                carNode?.removeFromParentNode()
                carNode = nil
                if c.showCar {
                    let color = uiColor(c.bodyColor)
                    let node = c.modelURL.flatMap { CarModelFactory.imported(url: $0, yawSteps: c.modelYawSteps, color: color) }
                        ?? CarModelFactory.provisional(color: color)
                    scene.rootNode.addChildNode(node)
                    carNode = node
                }
                lastModelKey = modelKey
            } else if c.bodyColor != last.bodyColor, let car = carNode {
                CarModelFactory.tint(car, uiColor(c.bodyColor))
            }
            if force || c.points != last.points || c.colors != last.colors || c.pointSize != last.pointSize {
                if c.points.isEmpty || c.points.count != c.colors.count {
                    ledNode.geometry = nil
                } else {
                    ledNode.geometry = LEDPointCloud.geometry(positions: c.points, colors: c.colors, pointSize: c.pointSize)
                }
            }
            if let s = c.selected, c.points.indices.contains(s) {
                let p = c.points[s]
                selectionNode.position = SCNVector3(p.x, p.y, p.z)
                selectionNode.isHidden = false
            } else {
                selectionNode.isHidden = true
            }
            if let t = c.twin, c.points.indices.contains(t) {
                let p = c.points[t]
                twinNode.position = SCNVector3(p.x, p.y, p.z)
                twinNode.isHidden = false
            } else {
                twinNode.isHidden = true
            }
            last = c
        }

        func move(to preset: CameraPreset, animated: Bool) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.6 : 0
            cameraNode.position = preset.position
            cameraNode.look(at: SCNVector3(0, 0.6, 0))
            SCNTransaction.commit()
            view?.pointOfView = cameraNode
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let loc = g.location(in: view)
            var best: (Int, CGFloat)?
            for (i, p) in last.points.enumerated() {
                let sp = view.projectPoint(SCNVector3(p.x, p.y, p.z))
                guard sp.z > 0, sp.z < 1 else { continue }
                let d = hypot(CGFloat(sp.x) - loc.x, CGFloat(sp.y) - loc.y)
                if d < 26, d < (best?.1 ?? .infinity) { best = (i, d) }
            }
            onSelect?(best?.0)
        }

        private func uiColor(_ c: RGB) -> UIColor {
            UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
        }
    }
}
