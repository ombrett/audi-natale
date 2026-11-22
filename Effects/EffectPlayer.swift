import Foundation
import QuartzCore

/// Riproduce un programma (o una playlist) con il motore effetti.
/// Anteprima: solo calcolo e visualizzazione 3D. Live: ogni fotogramma calcolato viene anche
/// inviato alle centraline; il fotogramma successivo parte quando tutte hanno confermato, quindi
/// la frequenza reale è quella che il collegamento BLE consente (mostrata in `liveFPS`).
final class EffectPlayer: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case preview = "Anteprima"
        case live = "Live"
        var id: String { rawValue }
    }

    @Published var mode: Mode = .preview { didSet { if oldValue != mode { modeChanged() } } }
    @Published private(set) var isPlaying = false
    @Published private(set) var program: EffectProgram?
    @Published private(set) var playlist: Playlist?
    @Published private(set) var playlistIndex = 0
    /// Colori correnti (anteprima) o dell'ultimo fotogramma inviato (live).
    @Published private(set) var colors: [LEDKey: RGB] = [:]
    @Published private(set) var liveFPS: Double?
    @Published private(set) var lastFrameSeconds: Double?
    @Published private(set) var liveStatus: String?

    let hub: ControllerHub
    let library: EffectLibrary
    private var context: EffectContext?
    private var controllers: [ControllerConfig] = []
    private var displayTimer: Timer?
    private var startTime = CACurrentMediaTime()
    private var itemStart = CACurrentMediaTime()
    private var liveRunning = false
    private var frameTimes: [Double] = []
    var brightness = 60
    var window = 6

    init(hub: ControllerHub, library: EffectLibrary) {
        self.hub = hub
        self.library = library
    }

    func setMap(_ map: CarMap?) {
        context = map.map { EffectContext(points: $0.effectPoints) }
        controllers = hub.controllers
        if !isPlaying, let program { renderPreview(program, at: 0) }
    }

    var hasMap: Bool { context?.points.isEmpty == false }

    var time: Double { CACurrentMediaTime() - startTime }

    // MARK: Controllo

    func play(_ p: EffectProgram) {
        playlist = nil
        program = p
        start()
    }

    func play(_ pl: Playlist) {
        guard let first = pl.items.first, let p = library.program(first.programID) else { return }
        playlist = pl
        playlistIndex = 0
        program = p
        start()
    }

    /// Aggiorna il programma in riproduzione senza ripartire (modifiche dall'editor).
    func update(_ p: EffectProgram) {
        program = p
        if !isPlaying { renderPreview(p, at: time) }
    }

    func stop() {
        isPlaying = false
        displayTimer?.invalidate()
        liveRunning = false
        hub.cancelAll()
    }

    private func start() {
        startTime = CACurrentMediaTime()
        itemStart = startTime
        isPlaying = true
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        if mode == .live { startLive() }
    }

    private func modeChanged() {
        if mode == .live {
            if isPlaying { startLive() }
        } else {
            liveRunning = false
            liveFPS = nil
            liveStatus = nil
        }
    }

    private func tick() {
        guard isPlaying, let program else { return }
        advancePlaylistIfNeeded()
        if mode == .preview { renderPreview(program, at: time) }
    }

    private func advancePlaylistIfNeeded() {
        guard let pl = playlist, !pl.items.isEmpty else { return }
        let item = pl.items[playlistIndex % pl.items.count]
        if CACurrentMediaTime() - itemStart >= item.seconds {
            playlistIndex = (playlistIndex + 1) % pl.items.count
            itemStart = CACurrentMediaTime()
            if let p = library.program(pl.items[playlistIndex].programID) { program = p }
        }
    }

    private func renderPreview(_ p: EffectProgram, at t: Double) {
        guard let context else { colors = [:]; return }
        colors = EffectEngine.render(p, context: context, time: t)
    }

    // MARK: Live

    var liveReady: Bool { !hub.readyLinks.isEmpty }

    private func startLive() {
        guard !liveRunning else { return }
        guard liveReady else { liveStatus = "Nessuna centralina pronta: collegale dalla schermata Centraline."; return }
        guard context != nil else { liveStatus = "Serve una mappa salvata."; return }
        liveRunning = true
        frameTimes = []
        liveStatus = nil
        sendNextFrame()
    }

    private func sendNextFrame() {
        guard liveRunning, isPlaying, mode == .live, let program, let context else { liveRunning = false; return }
        let t = time
        let frame = EffectEngine.render(program, context: context, time: t)
        colors = frame   // il modello mostra esattamente ciò che viene inviato
        let targets = FrameSplitter.split(frame, controllers: controllers)
        let since = Date()
        let began = CACurrentMediaTime()
        hub.apply(targets, brightness: brightness, window: window)
        hub.whenIdle(since: since, timeout: 30) { [weak self] error in
            guard let self else { return }
            if let error {
                self.liveStatus = "Live interrotto: \(error)"
                self.liveRunning = false
                return
            }
            let dt = CACurrentMediaTime() - began
            self.lastFrameSeconds = dt
            self.frameTimes.append(dt)
            if self.frameTimes.count > 10 { self.frameTimes.removeFirst() }
            let avg = self.frameTimes.reduce(0, +) / Double(self.frameTimes.count)
            self.liveFPS = avg > 0 ? 1 / avg : nil
            // Minimo 0,15 s tra fotogrammi per non saturare le centraline.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.15 - dt)) { self.sendNextFrame() }
        }
    }

    /// Applica un'unica volta i colori attuali alle centraline (disegno statico).
    func sendOnce(_ colors: [LEDKey: RGB], completion: @escaping (String?) -> Void) {
        guard liveReady else { completion("Nessuna centralina pronta"); return }
        let since = Date()
        hub.apply(FrameSplitter.split(colors, controllers: hub.controllers), brightness: brightness, window: window)
        hub.whenIdle(since: since, completion: completion)
    }
}
