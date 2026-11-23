import SwiftUI

/// Stato di navigazione condiviso (sezione, selezione nello Studio) — tenuto fuori dalle viste così
/// aprire/chiudere pannelli non ricrea la scena 3D e non tocca la riproduzione.
final class AppUIState: ObservableObject {
    enum StudioMode: String, CaseIterable, Identifiable {
        case view3D = "Vista 3D"
        case map = "Mappa"
        var id: String { rawValue }
    }

    @Published var section: MainSection = .studio
    @Published var studioSelection: UUID?
    @Published var studioMode: StudioMode = .view3D
    @Published var showPresetPicker = false
    @Published var camera: CameraPreset = .iso
    @Published var cameraToken = 0
}
