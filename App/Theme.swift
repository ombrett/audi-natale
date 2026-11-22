import SwiftUI

/// Tema scuro "automotive": nero, antracite, accento cyan.
enum Theme {
    static let background = Color(red: 0.035, green: 0.039, blue: 0.045)
    static let surface = Color(red: 0.094, green: 0.102, blue: 0.114)
    static let surfaceHigh = Color(red: 0.145, green: 0.157, blue: 0.172)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.0, green: 0.86, blue: 0.96)
    static let accentDim = Color(red: 0.0, green: 0.86, blue: 0.96).opacity(0.18)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.58)
    static let ok = Color(red: 0.25, green: 0.88, blue: 0.55)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let danger = Color(red: 1.0, green: 0.33, blue: 0.33)

    static let mono = Font.system(.caption, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)

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
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.8), radius: on ? 6 : 2)
            .scaleEffect(on ? 1.15 : 1)
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
