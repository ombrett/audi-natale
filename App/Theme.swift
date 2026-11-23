import SwiftUI

/// Tema tecnico: fondo grafite, testo chiaro, separatori sottili, un solo accento menta
/// (selezione e azioni attive). Ambra e rosso solo per avvisi ed errori veri.
enum Theme {
    static let background = Color(red: 0.055, green: 0.063, blue: 0.075)      // #0E1013
    static let surface = Color(red: 0.086, green: 0.094, blue: 0.110)         // #16181C
    static let surfaceHigh = Color(red: 0.125, green: 0.137, blue: 0.157)     // #202328
    static let stroke = Color.white.opacity(0.09)
    static let accent = Color(red: 0.471, green: 0.918, blue: 0.757)          // #78EAC1 menta
    static let accentDim = Color(red: 0.471, green: 0.918, blue: 0.757).opacity(0.14)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.55)
    static let ok = accent
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let danger = Color(red: 1.0, green: 0.33, blue: 0.33)

    static let mono = Font.system(.caption, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoBody = Font.system(size: 16, design: .monospaced)

    static func hex(_ c: RGB) -> String { String(format: "#%02X%02X%02X", c.r, c.g, c.b) }

    static func color(for level: SafetyLevel) -> Color {
        switch level {
        case .documented: return ok
        case .experimental: return warning
        case .blocked: return danger
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage).foregroundStyle(Theme.accent)
                    }
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
        )
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing = false
    @State private var on = false

    var body: some View {
        // Nessun bagliore: un punto pieno; "pulsing" attenua appena l'opacità durante le operazioni in corso.
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulsing && on ? 0.45 : 1)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct AccentButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(filled ? color.opacity(configuration.isPressed ? 0.7 : 1) : color.opacity(0.14))
            )
            .foregroundStyle(filled ? Color.black : color)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DisabledDim: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        content.disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

extension View {
    func enabled(_ on: Bool) -> some View { modifier(DisabledDim(enabled: on)) }

    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

/// Separatore sottile a tutta larghezza.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.stroke).frame(height: 1) }
}

/// Riga "etichetta … valore" con valore in monospace, separata da una linea sottile.
struct SpecRow<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.body).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 12)
                trailing
            }
            .padding(.vertical, 11)
            Hairline()
        }
    }
}

extension SpecRow where Trailing == Text {
    init(_ title: String, value: String) {
        self.title = title
        self.trailing = Text(value).font(Theme.monoBody).foregroundColor(Theme.textPrimary)
    }
}
