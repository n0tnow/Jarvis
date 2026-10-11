import SwiftUI

/// JARVIS design tokens. All visual constants live here — views should not hard-code them.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
    }

    /// Opacity tokens for white-on-dark surfaces and text. Text tokens are chosen to keep ≥ 4.5:1 contrast on the HUD base.
    enum Opacity {
        static let surface = 0.05
        static let surfaceRaised = 0.09
        static let hairline = 0.12
        static let stroke = 0.20
        static let strokeStrong = 0.34

        static let textPrimary = 0.94
        static let textSecondary = 0.68
        static let textTertiary = 0.52
    }

    enum Duration {
        static let fast = 0.15
        static let standard = 0.30
        static let slow = 0.60
    }

    /// Glow radii for the few places that use a shadow glow.
    enum Glow {
        static let subtle: CGFloat = 4
        static let medium: CGFloat = 10
        static let strong: CGFloat = 18
    }

    enum Palette {
        /// Deep blue-black base used under the glass.
        static let ink = Color(red: 0.020, green: 0.035, blue: 0.060)
        static let accent = Color(red: 0.47, green: 0.82, blue: 0.96)       // cool ice-cyan
        static let accentDeep = Color(red: 0.28, green: 0.52, blue: 0.82)
        static let amber = Color(red: 1.00, green: 0.77, blue: 0.36)
        static let mint = Color(red: 0.47, green: 0.92, blue: 0.70)
        static let coral = Color(red: 1.00, green: 0.43, blue: 0.43)
        static let violet = Color(red: 0.66, green: 0.66, blue: 1.00)
    }

    enum Typography {
        // macOS has no system Dynamic Type, so sizes are explicit readable minimums
        // (nothing below 10.5 pt) and layouts stay flexible rather than fixed-height.
        static let wordmark = Font.system(size: 15, weight: .semibold, design: .default)
        static let title = Font.system(size: 17, weight: .medium, design: .default)
        static let headline = Font.system(size: 13.5, weight: .medium, design: .default)
        static let body = Font.system(size: 13, design: .default)
        static let caption = Font.system(size: 11.5, design: .default)
        static let label = Font.system(size: 10.5, weight: .semibold, design: .monospaced)
        static let mono = Font.system(size: 11, design: .monospaced)
        static let metric = Font.system(size: 22, weight: .light, design: .monospaced)
    }
}

extension JarvisState {
    /// Accent colour for the state. Always paired with `label` / `symbolName` — colour is never the only cue.
    var tint: Color {
        switch self {
        case .idle: Color(red: 0.38, green: 0.67, blue: 0.89)
        case .listening: Theme.Palette.accent
        case .thinking: Theme.Palette.violet
        case .working: Color(red: 0.40, green: 0.90, blue: 0.86)
        case .waitingForApproval: Theme.Palette.amber
        case .completed: Theme.Palette.mint
        case .error: Theme.Palette.coral
        }
    }
}

extension TaskStatus {
    var tint: Color {
        switch self {
        case .queued: Color.white.opacity(Theme.Opacity.textSecondary)
        case .running: Theme.Palette.accent
        case .paused: Theme.Palette.amber
        case .waiting: Theme.Palette.amber
        case .completed: Theme.Palette.mint
        case .failed: Theme.Palette.coral
        case .cancelled: Color.white.opacity(Theme.Opacity.textTertiary)
        case .interrupted: Theme.Palette.amber
        }
    }
}

extension StepStatus {
    var tint: Color {
        switch self {
        case .pending: Color.white.opacity(Theme.Opacity.textTertiary)
        case .active: Theme.Palette.accent
        case .completed: Theme.Palette.mint
        case .failed: Theme.Palette.coral
        }
    }
}

extension ActivityKind {
    var tint: Color {
        switch self {
        case .info: Theme.Palette.accent
        case .success: Theme.Palette.mint
        case .warning: Theme.Palette.amber
        case .error: Theme.Palette.coral
        case .command: Theme.Palette.violet
        case .system: Color.white.opacity(Theme.Opacity.textSecondary)
        }
    }
}

extension Color {
    static func jarvisText(_ opacity: Double) -> Color { Color.white.opacity(opacity) }
    static let jarvisPrimary = Color.white.opacity(Theme.Opacity.textPrimary)
    static let jarvisSecondary = Color.white.opacity(Theme.Opacity.textSecondary)
    static let jarvisTertiary = Color.white.opacity(Theme.Opacity.textTertiary)
}

// MARK: - Layout environment

private struct HUDNarrowKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when the Full HUD is narrow (near its minimum width): panels slim down, labels shorten.
    var hudIsNarrow: Bool {
        get { self[HUDNarrowKey.self] }
        set { self[HUDNarrowKey.self] = newValue }
    }
}

// MARK: - Text styles

extension View {
    /// Small tracked uppercase technical label.
    func jarvisLabel(_ opacity: Double = Theme.Opacity.textSecondary) -> some View {
        self.font(Theme.Typography.label)
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(Color.white.opacity(opacity))
    }
}
