import Foundation
import CoreGraphics

/// Esegue la sequenza di mappatura: mostra ogni fotogramma del piano sui LED (DOOD confermati),
/// attende la fine dell'invio e un tempo di assestamento, cattura e media i fotogrammi, decodifica.
final class MappingEngine: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case running(step: Int, total: Int, label: String)
        case decoding
        case done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .running, .decoding: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var points: [MappedPoint] = []
    @Published private(set) var summary: MappingDecoder.Summary?
    @Published private(set) var snapshot: CGImage?
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var elapsed: TimeInterval = 0

    let ideal: IdealController
    let camera: CameraCapture
    let settings: AppSettings

    private var plan = MappingPlan(ledCount: 1)
    private var frames: [MappingPlan.Frame: GrayImage] = [:]
    private var cancelled = false
    private var startedAt = Date()
    private var poll: Timer?
    private var onColor: RGB = .green

    /// Attesa dopo la conferma dell'ultimo DOOD prima di catturare (latenza di aggiornamento LED + sensore).
    var settleDelay: TimeInterval = 0.6
    var framesPerCapture = 3

    init(ideal: IdealController, camera: CameraCapture, settings: AppSettings) {
        self.ideal = ideal
        self.camera = camera
        self.settings = settings
    }

    var plannedFrames: Int { MappingPlan(ledCount: settings.ledCount).frames.count }

    func run(shutter: Double, color: RGB) {
        guard !phase.isBusy else { return }
        guard ideal.canDraw else {
            phase = .failed("Controller non pronto: completa la verifica nel Bluetooth Lab.")
            return
        }
        guard camera.running else {
            phase = .failed("Fotocamera non attiva.")
            return
        }
        cancelled = false
        onColor = color
        plan = MappingPlan(ledCount: min(settings.ledCount, IdealProtocol.maxSafeLEDs))
        frames = [:]
        points = []
        summary = nil
        snapshot = nil
        startedAt = Date()
        phase = .preparing
        ideal.ble.log.add(.event, nil, "Mappatura: \(plan.ledCount) LED, \(plan.bits) bit, \(plan.frames.count) fotogrammi")
        camera.lockExposure(shutter: shutter) { [weak self] ok in
            guard let self, !self.cancelled else { return }
            guard ok else { self.fail("Impossibile bloccare l'esposizione"); return }
            self.step(0)
        }
    }

    func cancel() {
        cancelled = true
        poll?.invalidate()
        ideal.cancelTransfer()
        camera.unlockExposure()
        if phase.isBusy { phase = .idle }
    }

    func reset() {
        guard !phase.isBusy else { return }
        points = []
        summary = nil
        snapshot = nil
        phase = .idle
    }

    private func step(_ k: Int) {
        guard !cancelled else { return }
        guard k < plan.frames.count else { decode(); return }
        let frame = plan.frames[k]
        phase = .running(step: k + 1, total: plan.frames.count, label: frame.label)
        elapsed = Date().timeIntervalSince(startedAt)
        let requested = Date()
        ideal.apply(target: plan.pattern(for: frame, on: onColor))
        waitForTransfer(since: requested) { [weak self] error in
            guard let self, !self.cancelled else { return }
            if let error { self.fail(error); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.settleDelay) {
                guard !self.cancelled else { return }
                self.camera.grab(count: self.framesPerCapture, skip: 3, snapshot: frame == .allOn) { img, cg in
                    guard !self.cancelled else { return }
                    guard let img else { self.fail("Fotogramma non catturato"); return }
                    self.frames[frame] = img
                    if let cg { self.snapshot = cg }
                    if frame == .allOn { self.imageSize = CGSize(width: img.width, height: img.height) }
                    self.step(k + 1)
                }
            }
        }
    }

    private func waitForTransfer(since: Date, completion: @escaping (String?) -> Void) {
        poll?.invalidate()
        let deadline = Date().addingTimeInterval(30)
        poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.cancelled { timer.invalidate(); return }
            if let t = self.ideal.transfer, t.startedAt >= since {
                if let e = t.error { timer.invalidate(); completion(e); return }
                if t.finishedAt != nil { timer.invalidate(); completion(nil); return }
            }
            if Date() > deadline {
                timer.invalidate()
                completion(self.ideal.lastResult ?? "Invio del fotogramma non completato entro 30 s")
            }
        }
    }

    private func decode() {
        phase = .decoding
        let plan = self.plan
        let frames = self.frames
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pts = MappingDecoder.decode(plan: plan, frames: frames)
            let sum = MappingDecoder.summarize(pts, ledCount: plan.ledCount)
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                self.points = pts
                self.summary = sum
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                self.phase = .done
                self.camera.unlockExposure()
                self.frames = [:]   // libera memoria
                self.ideal.ble.log.add(.event, nil, "Mappatura: \(sum.points) punti, \(sum.uniqueIndices) indici, \(sum.missing.count) mancanti, \(String(format: "%.0f", self.elapsed)) s")
            }
        }
    }

    private func fail(_ reason: String) {
        poll?.invalidate()
        camera.unlockExposure()
        phase = .failed(reason)
        ideal.ble.log.add(.error, nil, "Mappatura interrotta: \(reason)")
    }
}
