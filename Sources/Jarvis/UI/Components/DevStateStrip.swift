import SwiftUI

/// DEVELOPMENT ONLY: forces any `JarvisState` so the visual state machine can be tested without AI.
/// Visible when Settings ▸ Show Developer Controls is on.
struct DevStateStrip: View {
    @Environment(AppContext.self) private var app
    /// Compact = icon-only chips (Compact HUD). Otherwise icon + label.
    var compact = false
    @Environment(\.hudIsNarrow) private var isNarrow
    private var iconOnly: Bool { compact || isNarrow }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            HStack {
                Text("DEV · STATE SIMULATOR").jarvisLabel(Theme.Opacity.textTertiary)
                Spacer()
                if !compact {
                    Button(isNarrow ? "RESET" : "RESET DEMO TASK") { DemoScenario.resetDemoTask(app.store) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Palette.accent)
                        .accessibilityLabel("Reset demo task")
                    Button(isNarrow ? "+ EVENT" : "ADD DEMO EVENT") { DemoScenario.addDemoEvent(app.store) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Palette.accent)
                        .accessibilityLabel("Add demo event")
                }
            }
            HStack(spacing: Theme.Spacing.xs + 1) {
                ForEach(JarvisState.allCases) { state in
                    chip(for: state)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Developer state simulator")
    }

    private func chip(for state: JarvisState) -> some View {
        let isCurrent = app.store.state == state
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
        return Button {
            DemoScenario.apply(state, to: app.store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.symbolName).font(.system(size: 11, weight: .medium))
                if !iconOnly {
                    Text(state.shortLabel)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isCurrent ? Theme.Palette.ink : Color.jarvisSecondary)
            .padding(.horizontal, iconOnly ? 0 : Theme.Spacing.s)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(shape.fill(isCurrent ? state.tint : Color.white.opacity(Theme.Opacity.surface)))
            .overlay(shape.strokeBorder(isCurrent ? Color.clear : Color.white.opacity(Theme.Opacity.hairline), lineWidth: 0.8))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(state.label.capitalized)
        .accessibilityLabel("Set state \(state.label.capitalized)")
        .accessibilityIdentifier("dev.state.\(state.rawValue)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
