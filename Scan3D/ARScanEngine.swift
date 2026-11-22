import Foundation
import ARKit
import AVFoundation
import simd

/// Scansione 3D guidata: per ogni vista le centraline mostrano i codici binari (tutte insieme),
/// ARKit fornisce posa e (se presente il LiDAR) profondità, i LED rilevati diventano punti 3D o
/// raggi; più viste vengono combinate con `LEDReconstructor`.
final class ARScanEngine: NSObject, ObservableObject, ARSessionDelegate {
    enum Phase: Equatable {
        case idle
        case running(step: Int, total: Int, label: String)
        case processing
        case failed(String)
        var isBusy: Bool {
            switch self {
            case .running, .processing: return true
            default: return false
            }
        }
    }

    struct ViewRecord: Identifiable, Equatable {
        let id: Int
        var name: String
        var detections: Int
        var decoded: Int
        var depthPoints: Int
        var movedCm: Double
        var accepted: Bool
        var note: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var views: [ViewRecord] = []
    @Published private(set) var reconstructed: [ReconstructedLED] = []
    @Published private(set) var trackingText = "Avvio AR…"
    @Published private(set) var trackingGood = false
    @Published private(set) var hasDepth = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var observations: [LEDObservation] = []

    let session = ARSession()
    let hub: ControllerHub
    private var codebook: Codebook
    private var frames: [MappingPlan.Frame: GrayImage] = [:]
    private var cameraAtOn: (transform: simd_float4x4, fx: Double, fy: Double, cx: Double, cy: Double)?
    private var depthAtOn: (map: [Float], conf: [UInt8], w: Int, h: Int)?
    private var firstPosition: SIMD3<Float>?
    private var lastPosition: SIMD3<Float>?
    private var cancelled = false
    private var startedAt = Date()
    private var grab: (remaining: Int, skip: Int, images: [GrayImage], frame: MappingPlan.Frame, done: (GrayImage?) -> Void)?
    private var color: RGB = .green
    private var copies: [UUID: Int] = [:]

    var settleDelay: TimeInterval = 0.6
    var brightness = 60
    var window = 6
    /// Lato lungo dell'immagine di analisi (l'immagine della camera AR è 1920×1440).
    private let analysisLong = 640

    init(hub: ControllerHub) {
        self.hub = hub
        self.codebook = hub.codebook
        super.init()
        session.delegate = self
    }

    var totalLEDs: Int { codebook.total }

    func startSession() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            hasDepth = true
        }
        session.run(config, options: [])
    }

    func pauseSession() { session.pause() }

    /// Riparte da osservazioni salvate (per completare una mappa esistente).
    func resume(from map: CarMap) {
        observations = map.observations
        views = (0..<map.viewCount).map { ViewRecord(id: $0, name: "Vista \($0 + 1) (salvata)", detections: 0, decoded: 0, depthPoints: 0, movedCm: 0, accepted: true, note: "") }
        recompute()
    }

    func reset() {
        guard !phase.isBusy else { return }
        observations = []
        views = []
        reconstructed = []
        phase = .idle
    }

    // MARK: Una vista

    func scanView(name: String, color: RGB, shutter: Double) {
        guard !phase.isBusy else { return }
        codebook = hub.codebook
        guard codebook.total > 0, hub.allReady else {
            phase = .failed("Collega e verifica tutte le centraline attive prima della scansione.")
            return
        }
        guard trackingGood else {
            phase = .failed("Tracciamento AR non pronto: muovi lentamente il telefono finché diventa verde.")
            return
        }
        copies = Dictionary(uniqueKeysWithValues: hub.enabledControllers.map { ($0.id, $0.copiesPerPixel) })
        self.color = color
        cancelled = false
        frames = [:]
        cameraAtOn = nil
        depthAtOn = nil
        firstPosition = nil
        lastPosition = nil
        startedAt = Date()
        lockExposure(shutter)
        hub.log.add(.event, nil, "Scansione 3D vista \"\(name)\": \(codebook.total) LED, \(codebook.plan.frames.count) fotogrammi")
        step(0, name: name)
    }

    func cancel() {
        cancelled = true
        grab = nil
        hub.cancelAll()
        unlockExposure()
        if phase.isBusy { phase = .idle }
    }

    private func step(_ k: Int, name: String) {
        guard !cancelled else { return }
        let plan = codebook.plan
        guard k < plan.frames.count else { finishView(name: name); return }
        let frame = plan.frames[k]
        phase = .running(step: k + 1, total: plan.frames.count, label: frame.label)
        elapsed = Date().timeIntervalSince(startedAt)
        let since = Date()
        hub.apply(codebook.targets(for: frame, on: color), brightness: brightness, window: window)
        hub.whenIdle(since: since) { [weak self] error in
            guard let self, !self.cancelled else { return }
            if let error { self.fail(error); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.settleDelay) {
                guard !self.cancelled else { return }
                self.grab = (3, 3, [], frame, { img in
                    guard !self.cancelled else { return }
                    guard let img else { self.fail("Fotogramma non catturato"); return }
                    self.frames[frame] = img
                    self.step(k + 1, name: name)
                })
            }
        }
    }

    private func finishView(name: String) {
        phase = .processing
        unlockExposure()
        let plan = codebook.plan
        let frames = self.frames
        let cam = cameraAtOn
        let depth = depthAtOn
        let moved = Double(simd_distance(firstPosition ?? .zero, lastPosition ?? .zero)) * 100
        let viewIndex = (views.map { $0.id }.max() ?? -1) + 1
        let book = codebook
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let points = MappingDecoder.decode(plan: plan, frames: frames)
            var obs: [LEDObservation] = []
            var depthCount = 0
            if let cam, let size = frames[.allOn].map({ ($0.width, $0.height) }) {
                for p in points {
                    guard let g = p.index, let key = book.key(forGlobal: g) else { continue }
                    let u = p.x * Double(size.0 - 1), v = p.y * Double(size.1 - 1)
                    let dirCam = SIMD3<Double>((u - cam.cx) / cam.fx, -(v - cam.cy) / cam.fy, -1)
                    let t = cam.transform
                    let origin = SIMD3<Double>(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
                    let r = simd_double3x3(columns: (
                        SIMD3<Double>(Double(t.columns.0.x), Double(t.columns.0.y), Double(t.columns.0.z)),
                        SIMD3<Double>(Double(t.columns.1.x), Double(t.columns.1.y), Double(t.columns.1.z)),
                        SIMD3<Double>(Double(t.columns.2.x), Double(t.columns.2.y), Double(t.columns.2.z))))
                    let ray = Ray(origin: origin, direction: r * dirCam)
                    var point: SIMD3<Double>?
                    if let depth {
                        let dx = min(depth.w - 1, max(0, Int(p.x * Double(depth.w - 1))))
                        let dy = min(depth.h - 1, max(0, Int(p.y * Double(depth.h - 1))))
                        let i = dy * depth.w + dx
                        let d = Double(depth.map[i])
                        if depth.conf[i] >= 1, d > 0.2, d < 8 {
                            point = origin + r * (dirCam * d)
                            depthCount += 1
                        }
                    }
                    obs.append(LEDObservation(key: key, view: viewIndex, point: point, ray: ray, weight: 1))
                }
            }
            let decoded = points.filter { $0.index != nil }.count
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                let accepted = moved <= 5 && cam != nil
                let note = cam == nil ? "Posa AR assente" : (moved > 5 ? String(format: "Telefono mosso di %.0f cm: vista scartata, ripeti tenendolo fermo.", moved) : "")
                self.views.append(ViewRecord(id: viewIndex, name: name, detections: points.count, decoded: decoded,
                                             depthPoints: depthCount, movedCm: moved, accepted: accepted, note: note))
                if accepted { self.observations += obs }
                self.recompute()
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                self.phase = .idle
                self.frames = [:]
                self.hub.log.add(.event, nil, "Vista \"\(name)\": \(points.count) punti, \(decoded) decodificati, \(depthCount) con profondità, spostamento \(Int(moved)) cm\(accepted ? "" : " — scartata")")
            }
        }
    }

    func removeView(_ id: Int) {
        guard !phase.isBusy else { return }
        observations.removeAll { $0.view == id }
        views.removeAll { $0.id == id }
        recompute()
    }

    private func recompute() {
        let obs = observations
        let maxCopies = max(copies.values.max() ?? 2, 1)
        let result = LEDReconstructor.reconstruct(obs, maxCopies: maxCopies)
        reconstructed = result.filter { r in
            // Rispetta le copie configurate per ogni centralina.
            let limit = copies[r.key.controller] ?? maxCopies
            return result.filter { $0.key == r.key }.firstIndex(of: r).map { $0 < limit } ?? true
        }
    }

    /// Mappa pronta da salvare.
    func makeMap(name: String) -> CarMap {
        let leds = reconstructed.map { PhysicalLED(key: $0.key, world: $0.position, confidence: $0.confidence, views: $0.views) }
        var map = CarMap(name: name, leds: leds)
        map.alignment = AutoAlign.fit(leds.map { $0.world })
        // Con il layout di progetto gli stessi pixel hanno una posizione prevista: allineamento esatto, verso compreso.
        if let fit = ProjectLayout.register(map, controllers: hub.controllers) {
            if fit.isGood {
                map.alignment = fit.alignment
                map.alignmentInfo = "Allineata al progetto automaticamente: " + fit.summary
            } else {
                map.alignmentInfo = "Allineamento al progetto non affidabile (" + fit.summary + "): usato l'allineamento per forma, controlla davanti/dietro."
            }
        }
        map.observations = observations
        map.viewCount = views.filter { $0.accepted }.count
        return map
    }

    private func fail(_ reason: String) {
        unlockExposure()
        grab = nil
        phase = .failed(reason)
        hub.log.add(.error, nil, "Scansione 3D: \(reason)")
    }

    // MARK: Esposizione

    private func lockExposure(_ shutter: Double) {
        guard let dev = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              (try? dev.lockForConfiguration()) != nil else { return }
        let f = dev.activeFormat
        let s = min(max(shutter, CMTimeGetSeconds(f.minExposureDuration)), CMTimeGetSeconds(f.maxExposureDuration))
        if dev.isExposureModeSupported(.custom) {
            dev.setExposureModeCustom(duration: CMTimeMakeWithSeconds(s, preferredTimescale: 1_000_000),
                                      iso: min(max(f.minISO * 2, f.minISO), f.maxISO), completionHandler: nil)
        }
        if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
        dev.unlockForConfiguration()
    }

    private func unlockExposure() {
        guard let dev = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              (try? dev.lockForConfiguration()) != nil else { return }
        if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
        dev.unlockForConfiguration()
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            trackingGood = true
            trackingText = "Tracciamento AR ok"
        case .notAvailable:
            trackingGood = false
            trackingText = "Tracciamento AR non disponibile"
        case .limited(let reason):
            trackingGood = false
            switch reason {
            case .excessiveMotion: trackingText = "Movimento troppo rapido"
            case .insufficientFeatures: trackingText = "Inquadra superfici con più dettagli"
            case .initializing: trackingText = "Inizializzazione: muovi lentamente il telefono"
            case .relocalizing: trackingText = "Rilocalizzazione…"
            @unknown default: trackingText = "Tracciamento limitato"
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        trackingGood = false
        trackingText = "Errore AR: \(error.localizedDescription)"
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard var g = grab else { return }
        let t = frame.camera.transform
        let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        if firstPosition == nil { firstPosition = pos }
        lastPosition = pos
        if g.skip > 0 { g.skip -= 1; grab = g; return }
        guard let img = luminance(frame.capturedImage) else { grab = nil; g.done(nil); return }
        g.images.append(img.image)
        if g.frame == .allOn && cameraAtOn == nil {
            let k = frame.camera.intrinsics
            let f = img.factor
            cameraAtOn = (t, Double(k[0][0]) / f, Double(k[1][1]) / f, Double(k[2][0]) / f, Double(k[2][1]) / f)
            if let depth = frame.sceneDepth { depthAtOn = copyDepth(depth) }
        }
        g.remaining -= 1
        if g.remaining <= 0 {
            grab = nil
            g.done(GrayImage.average(g.images))
        } else {
            grab = g
        }
    }

    /// Piano Y (luminanza) dell'immagine YCbCr, ridotto con media a blocchi.
    private func luminance(_ buffer: CVPixelBuffer) -> (image: GrayImage, factor: Double)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let f = max(1, max(w, h) / analysisLong)
        let ow = w / f, oh = h / f
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: ow * oh)
        let norm = 1 / Float(f * f)
        for oy in 0..<oh {
            for ox in 0..<ow {
                var acc: Float = 0
                for dy in 0..<f {
                    let r = ptr + (oy * f + dy) * row + ox * f
                    for dx in 0..<f { acc += Float(r[dx]) }
                }
                out[oy * ow + ox] = acc * norm
            }
        }
        return (GrayImage(width: ow, height: oh, pixels: out), Double(f))
    }

    private func copyDepth(_ d: ARDepthData) -> (map: [Float], conf: [UInt8], w: Int, h: Int)? {
        let m = d.depthMap
        CVPixelBufferLockBaseAddress(m, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(m, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(m) else { return nil }
        let w = CVPixelBufferGetWidth(m), h = CVPixelBufferGetHeight(m), row = CVPixelBufferGetBytesPerRow(m)
        var map = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let r = (base + y * row).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { map[y * w + x] = r[x] }
        }
        var conf = [UInt8](repeating: 2, count: w * h)
        if let c = d.confidenceMap {
            CVPixelBufferLockBaseAddress(c, .readOnly)
            if let cb = CVPixelBufferGetBaseAddress(c) {
                let crow = CVPixelBufferGetBytesPerRow(c)
                for y in 0..<min(h, CVPixelBufferGetHeight(c)) {
                    let r = (cb + y * crow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<min(w, CVPixelBufferGetWidth(c)) { conf[y * w + x] = r[x] }
                }
            }
            CVPixelBufferUnlockBaseAddress(c, .readOnly)
        }
        return (map, conf, w, h)
    }
}
