import Foundation

/// Carica in background il pacchetto di 60 animazioni incluso nell'app (AudiLightStudio_Effetti.json).
final class ClipLibrary: ObservableObject {
    @Published private(set) var pack: FramePack?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false

    static var bundledURL: URL? { Bundle.main.url(forResource: "AudiLightStudio_Effetti", withExtension: "json") }

    func loadIfNeeded() {
        guard pack == nil, !isLoading else { return }
        guard let url = Self.bundledURL else { error = "Pacchetto effetti non incluso in questa build."; return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<FramePack, Error> = Result { try FramePack.load(try Data(contentsOf: url, options: .mappedIfSafe)) }
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let p): self.pack = p; self.error = nil
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }
}
