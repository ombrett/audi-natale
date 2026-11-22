import Foundation
import UIKit
import CoreGraphics

/// Una mappa 2D per inquadratura. Le coordinate sono normalizzate (0…1) sull'immagine:
/// è una proiezione 2D, non una ricostruzione 3D.
struct LEDMapSection: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var ledCount: Int
    var imageWidth: Int
    var imageHeight: Int
    var points: [MappedPoint]
    var snapshotFile: String?

    var aspect: CGFloat { imageHeight > 0 ? CGFloat(imageWidth) / CGFloat(imageHeight) : 9.0 / 16.0 }
    var summary: MappingDecoder.Summary { MappingDecoder.summarize(points, ledCount: ledCount) }
}

final class LEDMapStore: ObservableObject {
    @Published private(set) var sections: [LEDMapSection] = []
    private let dir: URL
    private var indexURL: URL { dir.appendingPathComponent("maps.json") }

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("Maps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([LEDMapSection].self, from: data) {
            sections = list
        }
    }

    @discardableResult
    func add(name: String, ledCount: Int, imageSize: CGSize, points: [MappedPoint], snapshot: CGImage?) -> LEDMapSection {
        var section = LEDMapSection(name: name.isEmpty ? "Sezione \(sections.count + 1)" : name,
                                    ledCount: ledCount, imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height),
                                    points: points, snapshotFile: nil)
        if let cg = snapshot, let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.7) {
            let file = section.id.uuidString + ".jpg"
            if (try? data.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil {
                section.snapshotFile = file
            }
        }
        sections.append(section)
        persist()
        return section
    }

    func update(_ section: LEDMapSection) {
        guard let i = sections.firstIndex(where: { $0.id == section.id }) else { return }
        sections[i] = section
        persist()
    }

    func delete(_ section: LEDMapSection) {
        if let f = section.snapshotFile { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        sections.removeAll { $0.id == section.id }
        persist()
    }

    func image(for section: LEDMapSection) -> UIImage? {
        guard let f = section.snapshotFile else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(f).path)
    }

    /// Unione delle sezioni: per ogni indice, in quante sezioni compare.
    func coverage(ledCount: Int) -> [Int: Int] {
        var c: [Int: Int] = [:]
        for s in sections {
            for i in Set(s.points.compactMap { $0.index }) where i < ledCount { c[i, default: 0] += 1 }
        }
        return c
    }

    /// Esporta tutte le mappe come JSON (Documents/Logs) per backup o analisi.
    func exportJSON() throws -> URL {
        let out = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = out.appendingPathComponent("led-map-\(PacketLog.fileStamp()).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(sections).write(to: url, options: .atomic)
        return url
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sections) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

enum IndexRanges {
    /// [1,2,3,7,9,10] → "1–3, 7, 9–10"
    static func text(_ values: [Int], limit: Int = 12) -> String {
        let sorted = Array(Set(values)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i])" : "\(sorted[i])–\(sorted[j])")
            i = j + 1
        }
        if parts.count > limit { return parts.prefix(limit).joined(separator: ", ") + " … (+\(parts.count - limit))" }
        return parts.joined(separator: ", ")
    }
}
