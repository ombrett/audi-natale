import SwiftUI
import SceneKit
import simd

/// Contenuto da disegnare nella scena 3D.
struct CarSceneContent: Equatable {
    var points: [SIMD3<Float>] = []
    var colors: [SIMD4<Float>] = []
    var selected: Int?
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
        context.coordinator.view = view
        context.coordinator.apply(content, force: true)
        context.coordinator.move(to: camera, animated: false)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.apply(content, force: false)
        if context.coordinator.cameraToken != cameraToken {
            context.coordinator.cameraToken = cameraToken
            context.coordinator.move(to: camera, animated: true)
        }
    }

    final class Coordinator: NSObject {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        weak var view: SCNView?
        var onSelect: ((Int?) -> Void)?
        var cameraToken = 0
        private var carNode: SCNNode?
        private let ledNode = SCNNode()
        private let selectionNode = SCNNode()
        private var last = CarSceneContent()
        private var lastModelKey = ""

        override init() {
            super.init()
            let cam = SCNCamera()
            cam.fieldOfView = 45
            cam.zNear = 0.05
            cam.zFar = 100
            cam.wantsHDR = true
            cam.bloomIntensity = 1.2
            cam.bloomThreshold = 0.6
            cam.bloomBlurRadius = 6
            cameraNode.camera = cam
            scene.rootNode.addChildNode(cameraNode)

            scene.lightingEnvironment.contents = CarMeshBuilder.environmentImage()
            scene.lightingEnvironment.intensity = 1.2
            let floor = SCNFloor()
            floor.reflectivity = 0.12
            floor.reflectionFalloffEnd = 2.5
            let fm = SCNMaterial()
            fm.lightingModel = .physicallyBased
            fm.diffuse.contents = UIColor(white: 0.035, alpha: 1)
            fm.roughness.contents = 0.6
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
            let ring = SCNTorus(ringRadius: 0.06, pipeRadius: 0.008)
            let rm = SCNMaterial(); rm.lightingModel = .constant; rm.diffuse.contents = UIColor(Theme.accent)
            ring.materials = [rm]
            selectionNode.geometry = ring
            selectionNode.isHidden = true
            selectionNode.constraints = [SCNBillboardConstraint()]
            scene.rootNode.addChildNode(selectionNode)
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
