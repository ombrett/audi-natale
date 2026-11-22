import Foundation

/// Disegni salvati in locale (JSON in Application Support).
struct DrawingPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var pixels: [RGB]
    var savedAt = Date()
}

final class PresetStore: ObservableObject {
    @Published private(set) var presets: [DrawingPreset] = []
    private let url: URL

    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent("presets.json")
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([DrawingPreset].self, from: data) {
            presets = list
        }
    }

    func save(name: String, pixels: [RGB]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = clean.isEmpty ? "Disegno \(presets.count + 1)" : clean
        if let i = presets.firstIndex(where: { $0.name == finalName }) {
            presets[i].pixels = pixels
            presets[i].savedAt = Date()
        } else {
            presets.append(DrawingPreset(name: finalName, pixels: pixels))
        }
        persist()
    }

    func delete(_ preset: DrawingPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
