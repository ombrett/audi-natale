import Foundation
import AVFoundation
import CoreImage
import UIKit

/// Cattura video con esposizione bloccata e conversione dei fotogrammi in GrayImage.
final class CameraCapture: NSObject, ObservableObject {
    @Published private(set) var authorized: Bool?
    @Published private(set) var running = false
    @Published private(set) var exposureLocked = false
    @Published private(set) var lastError: String?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.frames")
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private let ciContext = CIContext()
    /// Larghezza di analisi (lato corto in verticale). Più alta = LED vicini distinguibili meglio.
    var analysisWidth = 540

    private struct Grab {
        var remaining: Int
        var images: [GrayImage]
        var wantsSnapshot: Bool
        var snapshot: CGImage?
        var skip: Int
        let completion: (GrayImage?, CGImage?) -> Void
    }
    private var grab: Grab?   // accesso solo da `queue`

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    self?.authorized = ok
                    if ok { self?.configureAndRun() }
                }
            }
        default:
            authorized = false
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async { self?.running = false }
        }
    }

    private func configureAndRun() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty {
                self.session.beginConfiguration()
                self.session.sessionPreset = .hd1920x1080
                guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: dev), self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.lastError = "Fotocamera posteriore non disponibile" }
                    return
                }
                self.session.addInput(input)
                self.device = dev
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                if let conn = self.output.connection(with: .video) {
                    if #available(iOS 17.0, *) {
                        if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                    } else if conn.isVideoOrientationSupported {
                        conn.videoOrientation = .portrait
                    }
                }
                self.session.commitConfiguration()
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.running = self.session.isRunning }
        }
    }

    /// Blocca esposizione, bilanciamento del bianco e messa a fuoco.
    /// `shutter` in secondi (es. 1/250): tempi brevi scuriscono l'ambiente e non saturano i LED.
    func lockExposure(shutter: Double, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, let dev = self.device else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            do {
                try dev.lockForConfiguration()
                let format = dev.activeFormat
                let minD = CMTimeGetSeconds(format.minExposureDuration)
                let maxD = CMTimeGetSeconds(format.maxExposureDuration)
                let seconds = min(max(shutter, minD), maxD)
                let duration = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000)
                let iso = min(max(format.minISO * 2, format.minISO), format.maxISO)
                if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
                if dev.isExposureModeSupported(.custom) {
                    dev.setExposureModeCustom(duration: duration, iso: iso) { _ in
                        DispatchQueue.main.async {
                            self.exposureLocked = true
                            completion(true)
                        }
                    }
                } else {
                    if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                    DispatchQueue.main.async {
                        self.exposureLocked = true
                        completion(true)
                    }
                }
                dev.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    completion(false)
                }
            }
        }
    }

    func unlockExposure() {
        queue.async { [weak self] in
            guard let self, let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            dev.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureLocked = false }
        }
    }

    /// Scarta `skip` fotogrammi (ancora in arrivo dal sensore), poi media i successivi `count`.
    func grab(count: Int, skip: Int = 2, snapshot: Bool = false, completion: @escaping (GrayImage?, CGImage?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.grab = Grab(remaining: max(count, 1), images: [], wantsSnapshot: snapshot, snapshot: nil, skip: skip,
                             completion: { img, cg in DispatchQueue.main.async { completion(img, cg) } })
        }
    }

    private func gray(from buffer: CVPixelBuffer) -> GrayImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let f = max(1, w / max(analysisWidth, 1))
        let ow = w / f, oh = h / f
        guard ow > 0, oh > 0 else { return nil }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: ow * oh)
        let norm = 1 / Float(f * f)
        for oy in 0..<oh {
            for ox in 0..<ow {
                var acc: Float = 0
                for dy in 0..<f {
                    let row = ptr + (oy * f + dy) * rowBytes
                    for dx in 0..<f {
                        let p = row + (ox * f + dx) * 4   // BGRA
                        acc += 0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])
                    }
                }
                out[oy * ow + ox] = acc * norm
            }
        }
        return GrayImage(width: ow, height: oh, pixels: out)
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard var g = grab, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if g.skip > 0 {
            g.skip -= 1
            grab = g
            return
        }
        if g.wantsSnapshot && g.snapshot == nil {
            let ci = CIImage(cvPixelBuffer: buffer)
            g.snapshot = ciContext.createCGImage(ci, from: ci.extent)
        }
        if let img = gray(from: buffer) { g.images.append(img) }
        g.remaining -= 1
        if g.remaining <= 0 {
            grab = nil
            g.completion(GrayImage.average(g.images), g.snapshot)
        } else {
            grab = g
        }
    }
}
