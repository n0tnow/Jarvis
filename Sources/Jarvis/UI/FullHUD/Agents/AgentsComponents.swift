import SwiftUI

// MARK: - Presentation helpers

extension ProviderUIState {
    var tint: Color {
        switch self {
        case .running, .starting: Theme.Palette.accent
        case .ready, .loadedIdle: Theme.Palette.mint
        case .unloaded, .checking: Color.jarvisSecondary
        case .rateLimited, .cooldown, .authRequired: Theme.Palette.amber
        case .notInstalled, .unavailable: Color.jarvisTertiary
        case .failed: Theme.Palette.coral
        }
    }
    /// A glyph so state never relies on colour alone.
    var symbol: String {
        switch self {
        case .running: "play.fill"
        case .starting: "hourglass"
        case .ready, .loadedIdle: "checkmark.circle"
        case .unloaded: "moon.zzz"
        case .checking: "ellipsis.circle"
        case .rateLimited, .cooldown: "pause.circle"
        case .authRequired: "key"
        case .notInstalled, .unavailable: "minus.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

extension RunPhase {
    var tint: Color {
        switch self {
        case .queued, .waiting: Color.jarvisSecondary
        case .starting, .running, .verifying: Theme.Palette.accent
        case .completed: Theme.Palette.mint
        case .failed: Theme.Palette.coral
        case .cancelled, .interrupted, .escalated: Theme.Palette.amber
        }
    }
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .starting: "hourglass"
        case .running: "play.fill"
        case .verifying: "checkmark.seal"
        case .waiting: "ellipsis.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle"
        case .interrupted: "bolt.slash"
        case .escalated: "arrow.up.right.circle"
        }
    }
}

extension EventSeverity {
    var tint: Color {
        switch self { case .info: Color.jarvisSecondary; case .success: Theme.Palette.mint; case .warning: Theme.Palette.amber; case .error: Theme.Palette.coral }
    }
    /// Text marker used in the console so severity survives without colour.
    var marker: String { switch self { case .info: " "; case .success: "✓"; case .warning: "!"; case .error: "✕" } }
}

enum DurationText {
    static func format(_ interval: TimeInterval) -> String { ElapsedText.format(interval) }
}

// MARK: - Small views

struct PhaseChip: View {
    let phase: RunPhase
    var simulated = false
    var body: some View {
        HStack(spacing: 4) {
            StatusChip(text: phase.label, symbol: phase.symbol, tint: phase.tint)
            if simulated { Tag(text: "SIMULATED", tint: Theme.Palette.violet) }
        }
    }
}

/// Measurable progress as a bar + "3 / 5 steps"; otherwise an HONEST indeterminate line (no percentage, no animation).
struct ProgressLine: View {
    let run: AgentRunView
    var now: Date = Date()

    var body: some View {
        if let f = run.progress.fraction, let label = run.progress.label {
            HStack(spacing: Theme.Spacing.s) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule().fill(run.phase.tint.opacity(0.9)).frame(width: max(3, g.size.width * f))
                    }
                }
                .frame(height: 4)
                Text(label).font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary).fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progress, \(run.progress.completed) of \(run.progress.total) steps completed")
        } else if run.phase.isActive {
            Text("\(run.phase == .queued ? "Queued" : "Working") — \(DurationText.format(run.elapsed(at: now))) · no measurable steps")
                .font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary)
                .accessibilityLabel("Working, progress unknown, \(DurationText.format(run.elapsed(at: now))) elapsed")
        }
    }
}

struct ElapsedLabel: View {
    let run: AgentRunView
    var body: some View {
        if run.phase.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(DurationText.format(run.elapsed(at: ctx.date))).monospacedDigit()
            }
        } else {
            Text(DurationText.format(run.elapsed())).monospacedDigit()
        }
    }
}

// MARK: - Provider card

struct ProviderCardView: View {
    let card: ProviderCardModel
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs + 1) {
                HStack {
                    Text(card.name).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary)
                    Spacer(minLength: 4)
                    StatusChip(text: card.state.label, symbol: card.state.symbol, tint: card.state.tint)
                }
                Text(card.state.explanation).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(2)
                if let a = card.activeRuns.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(a.agentType)\(card.activeRuns.count > 1 ? " +\(card.activeRuns.count - 1)" : "")").font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).lineLimit(1)
                        Text(a.label).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                        Text(a.activity).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.accent).lineLimit(1)
                        ProgressLine(run: a)
                    }
                } else if let last = card.lastRun {
                    Text("Last: \(last.agentType) · \(last.phase.label)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                }
                if let m = card.currentModel {
                    Text("Model: \(m.split(separator: "/").last.map(String.init) ?? m)").font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                }
                ForEach(card.facts.filter { !$0.hasSuffix("active run") && !$0.hasSuffix("active runs") }.prefix(3), id: \.self) { f in
                    Text(f).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(1)
                }
                if let c = card.cooldownUntil { Text("Cooldown until \(c.formatted(date: .omitted, time: .shortened))").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
                if let e = card.lastError, card.activeRuns.isEmpty { Text("Last problem: \(e)").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.coral.opacity(0.9)).lineLimit(1) }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HUDCardBackground(cornerRadius: Theme.Radius.m, accent: isSelected ? Theme.Palette.accent : Color.jarvisTertiary, raised: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("agents.provider.\(card.id.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var spoken: String {
        var s = "\(card.name), \(card.state.label.lowercased())"
        if let a = card.activeRuns.first { s += ", \(a.agentType), \(a.activity)"; if let l = a.progress.label { s += ", \(l)" } }
        if card.activeRuns.count > 1 { s += ", \(card.activeRuns.count) active runs" }
        if let m = card.currentModel { s += ", model \(m)" }
        return s
    }
}

// MARK: - Run row / card

struct RunRowView: View {
    let run: AgentRunView
    /// V0.4: the task this run executes for (runs are grouped under their task).
    var taskTitle: String? = nil
    var isSelected: Bool
    var onSelect: () -> Void
    var onStop: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(run.agentType).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).lineLimit(1)
                        PhaseChip(phase: run.phase, simulated: run.isSimulated)
                        Spacer(minLength: 0)
                        ElapsedLabel(run: run).font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary)
                    }
                    if let taskTitle { Text("TASK · \(taskTitle)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.Palette.violet).lineLimit(1) }
                    Text("\(AgentObservatory.providerLabel(run)) · \(run.label)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                    if run.phase.isActive { Text(run.activity).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.accent).lineLimit(1) }
                    else if let c = run.errorCategory { Text(run.activity.isEmpty ? c : run.activity).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(1) }
                    ProgressLine(run: run)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onStop, run.phase.isActive {
                Button(action: onStop) {
                    HStack(spacing: 3) { Image(systemName: "stop.fill").font(.system(size: 8.5, weight: .bold)); Text("STOP").font(.system(size: 10, weight: .semibold, design: .monospaced)) }
                        .foregroundStyle(Theme.Palette.coral)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Palette.coral.opacity(0.7), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop \(run.agentType)")
                .accessibilityHint("Cancels this run and ends its provider process")
                .accessibilityIdentifier("agents.stop.\(run.id.uuidString.prefix(8))")
            }
        }
        .padding(Theme.Spacing.s + 2)
        .background(HUDCardBackground(cornerRadius: Theme.Radius.s, accent: isSelected ? Theme.Palette.accent : Color.jarvisTertiary, raised: isSelected))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(run.spoken)
        .accessibilityIdentifier("agents.run.\(run.id.uuidString.prefix(8))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
