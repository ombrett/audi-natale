import Foundation

/// Riproduce in ciclo una sequenza di disegni (preset) generata dall'app.
/// Ogni passo attende la conferma di tutti i DOOD; l'intervallo effettivo non può essere più
/// breve del tempo di invio misurato, che viene mostrato.
final class SequencePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentName: String?
    @Published private(set) var lastStepDuration: TimeInterval?
    @Published private(set) var cycles = 0
    @Published private(set) var error: String?

    private var steps: [(name: String, pixels: [RGB])] = []
    private var index = 0
    private var interval: TimeInterval = 3
    private var poll: Timer?
    private var next: DispatchWorkItem?
    private weak var ideal: IdealController?
    private var mode: DIYMode = .static
    private var speed = 100

    func play(_ presets: [DrawingPreset], ledCount: Int, interval: TimeInterval, mode: DIYMode, speed: Int, ideal: IdealController) {
        stop()
        guard !presets.isEmpty else { return }
        steps = presets.map { p in
            (p.name, Array(p.pixels.prefix(ledCount)) + [RGB](repeating: .black, count: max(0, ledCount - p.pixels.count)))
        }
        self.ideal = ideal
        self.interval = interval
        self.mode = mode
        self.speed = speed
        index = 0
        cycles = 0
        error = nil
        isPlaying = true
        showCurrent()
    }

    func stop() {
        poll?.invalidate()
        next?.cancel()
        if isPlaying { ideal?.cancelTransfer() }
        isPlaying = false
        currentName = nil
    }

    private func showCurrent() {
        guard isPlaying, let ideal, !steps.isEmpty else { return }
        let step = steps[index]
        currentName = step.name
        let requested = Date()
        ideal.apply(target: step.pixels, mode: mode, speed: speed)
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, self.isPlaying, let ideal = self.ideal else { timer.invalidate(); return }
            guard let t = ideal.transfer, t.startedAt >= requested else {
                if Date().timeIntervalSince(requested) > 30 { timer.invalidate(); self.fail(ideal.lastResult ?? "Invio non partito") }
                return
            }
            if let e = t.error { timer.invalidate(); self.fail(e); return }
            guard t.finishedAt != nil else { return }
            timer.invalidate()
            let took = Date().timeIntervalSince(requested)
            self.lastStepDuration = took
            let work = DispatchWorkItem { [weak self] in self?.advance() }
            self.next = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, self.interval - took), execute: work)
        }
    }

    private func advance() {
        guard isPlaying else { return }
        index += 1
        if index >= steps.count {
            index = 0
            cycles += 1
        }
        showCurrent()
    }

    private func fail(_ reason: String) {
        error = reason
        isPlaying = false
        currentName = nil
    }
}
