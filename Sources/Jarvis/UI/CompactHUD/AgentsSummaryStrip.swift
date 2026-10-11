import SwiftUI

/// Restrained Compact summary of agent activity. Fixed height, tail-truncated text: it can NEVER change the 392×448 window
/// (no console output here — streaming belongs to the Full HUD). Hidden when there is nothing to report.
struct AgentsSummaryStrip: View {
    @Environment(AppContext.self) private var app
    static let height: CGFloat = 44

    /// What the strip would show right now (also used by the Compact layout to decide whether the developer strip yields).
    @MainActor static func shown(_ hub: ExecutionHub) -> AgentRunView? {
        hub.activeRuns.first ?? hub.recentFinished.first { Date().timeIntervalSince($0.finishedAt ?? .distantPast) < 600 }
    }

    var body: some View {
        let active = app.hub.activeRuns
        let shown = Self.shown(app.hub)
        Group {
            if let run = shown {
                Button { app.windows.showFullHUD(section: .agents); app.observatory.selectedRunID = run.id } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(active.isEmpty ? "AGENTS · LAST" : "AGENTS · \(active.count) ACTIVE").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.7)
                                .foregroundStyle(active.isEmpty ? Color.jarvisTertiary : Theme.Palette.accent)
                            if run.isSimulated { Text("SIMULATED").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.Palette.violet) }
                            Spacer(minLength: 0)
                            ElapsedLabel(run: run).font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary)
                        }
                        Text("\(AgentObservatory.providerLabel(run)) · \(run.agentType) · \(run.phase.isActive ? run.activity : run.phase.label.capitalized)")
                            .font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary).lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.horizontal, Theme.Spacing.s + 2).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HUDCardBackground(cornerRadius: Theme.Radius.s))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Agents. \(active.count) active. \(run.spoken). Opens the Full HUD.")
            }
        }
        .frame(height: shown == nil ? 0 : Self.height, alignment: .top)       // takes no space when idle; the window is fixed either way
    }
}
