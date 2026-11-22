import SwiftUI
import simd

enum LEDColoring: String, CaseIterable, Identifiable {
    case effect = "Effetto"
    case controller = "Centralina"
    case confidence = "Affidabilità"
    case zone = "Zona"
    var id: String { rawValue }
}

/// Colori distintivi delle zone della carrozzeria (modifica zone e legenda).
enum ZonePalette {
    static func rgb(_ z: AdaptiveEffects.Zone) -> RGB {
        switch z {
        case .paraurti_anteriore: return RGB(r: 255, g: 120, b: 40)
        case .cofano: return RGB(r: 255, g: 210, b: 40)
        case .montante_anteriore: return RGB(r: 150, g: 255, b: 80)
        case .tetto: return RGB(r: 40, g: 200, b: 255)
        case .montante_centrale: return RGB(r: 60, g: 255, b: 190)
        case .fiancata_anteriore: return RGB(r: 255, g: 70, b: 160)
        case .fiancata_posteriore: return RGB(r: 170, g: 90, b: 255)
        case .montante_posteriore: return RGB(r: 240, g: 240, b: 255)
        case .portellone: return RGB(r: 255, g: 40, b: 40)
        }
    }
    static func color(_ z: AdaptiveEffects.Zone) -> Color { Color(rgb: rgb(z)) }
}

enum LEDFilter: Hashable {
    case all
    case controller(UUID)
    case zone(CarZone)
}

enum ControllerPalette {
    static let colors: [RGB] = [
        RGB(r: 0, g: 220, b: 245), RGB(r: 255, g: 150, b: 0), RGB(r: 255, g: 60, b: 170),
        RGB(r: 80, g: 230, b: 100), RGB(r: 255, g: 225, b: 40), RGB(r: 150, g: 90, b: 255),
    ]
    static func rgb(_ tint: Int) -> RGB { colors[((tint % colors.count) + colors.count) % colors.count] }
    static func color(_ tint: Int) -> Color { Color(rgb: rgb(tint)) }
}

enum SceneContentBuilder {
    /// Converte mappa + colori correnti nel contenuto della scena 3D.
    /// Restituisce anche gli id dei LED fisici nello stesso ordine dei punti (per la selezione).
    static func build(map: CarMap?, colors: [LEDKey: RGB], coloring: LEDColoring, filter: LEDFilter,
                      controllers: [ControllerConfig], highlight: Set<LEDKey> = [], selected: UUID? = nil,
                      highlightIDs: Set<UUID> = [], zones: [UUID: AdaptiveEffects.Zone] = [:],
                      model: CarModelStore) -> (CarSceneContent, [UUID]) {
        var content = CarSceneContent()
        content.bodyColor = model.bodyColor
        content.modelURL = model.modelURL
        content.modelYawSteps = model.yawSteps
        guard let map else { return (content, []) }
        let tints = Dictionary(uniqueKeysWithValues: controllers.map { ($0.id, $0.tint) })
        var ids: [UUID] = []
        for led in map.leds {
            let car = map.carPosition(led)
            let visible: Bool
            switch filter {
            case .all: visible = true
            case .controller(let id): visible = led.key.controller == id
            case .zone(let z): visible = ZoneClassifier.contains(z, car)
            }
            var c: RGB
            switch coloring {
            case .effect: c = colors[led.key] ?? .black
            case .controller: c = ControllerPalette.rgb(tints[led.key.controller] ?? 0)
            case .confidence:
                let k = min(max(led.confidence, 0), 1)
                c = EffectEngine.mix(RGB(r: 255, g: 50, b: 50), RGB(r: 60, g: 230, b: 120), k)
            case .zone:
                c = zones[led.id].map { ZonePalette.rgb($0) } ?? RGB(r: 90, g: 90, b: 90)
            }
            if highlight.contains(led.key) || highlightIDs.contains(led.id) { c = RGB(r: 255, g: 255, b: 255) }
            content.points.append(SIMD3<Float>(Float(car.x), Float(car.y), Float(car.z)))
            content.colors.append(visible ? LEDPointCloud.color(c) : SIMD4<Float>(0.08, 0.08, 0.09, 1))
            ids.append(led.id)
        }
        if let s = selected { content.selected = ids.firstIndex(of: s) }
        return (content, ids)
    }
}
