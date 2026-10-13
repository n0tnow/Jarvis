import SwiftUI

// MARK: - The task graph (V0.12): nodes with role, provider, status, dependencies, validation — and a drill-down into artifacts and routing reasons.
// Correctness over decoration: a list, not a renderer. Never shows hidden reasoning; artifact text is the sanitized, bounded content JARVIS stored.

struct TaskGraphView: View {
    let view: TaskView
    let detail: OrchestrationDetail
    let developer: Bool
    @State private var selected: String?

    private var outcome: TaskOutcome { TaskOutcome.derive(state: view.task.state, failure: view.task.failureCategory, steps: view.steps) }

    var body: some View {
        let (done, total) = GraphProgress.validated(view.steps)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Text("GRAPH · \(view.steps.count) NODES").jarvisLabel(Theme.Opacity.textTertiary)
                if let g = detail.graph { Tag(text: g.planner == "model" ? "MODEL-PLANNED" : "ORCHESTRATOR").accessibilityLabel(g.planner == "model" ? "Planned by a model and validated by JARVIS" : "Planned by JARVIS") }
                Spacer(minLength: 0)
                Text("\(done)/\(total) REQUIRED VALIDATED").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Color.jarvisSecondary)
            }
            if view.task.state.isTerminal || view.task.state == .waitingForApproval || view.task.state == .interrupted {
                Text("Outcome: \(outcome.label)").font(Theme.Typography.caption).foregroundStyle(outcome == .success ? Theme.Palette.mint : (outcome == .partial || outcome == .blocked || outcome == .approvalRequired || outcome == .interrupted) ? Theme.Palette.amber : Color.jarvisSecondary)
                    .accessibilityLabel("Outcome \(outcome.label.lowercased())")
            }
            if let g = detail.graph, let why = g.rationale { Text(why).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(2) }
            ForEach(view.steps) { s in
                GraphNodeRow(step: s, provider: detail.providerLabel(node: s.key), expanded: selected == s.key, onToggle: { selected = selected == s.key ? nil : s.key })
                if selected == s.key { NodeDetail(step: s, detail: detail, developer: developer) }
            }
            ForEach(detail.revisions) { r in
                Label("Graph revision \(r.n): \(r.reason)", systemImage: "arrow.triangle.branch").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber)
            }
            if !detail.children.isEmpty {
                Text("DELEGATED TASKS").jarvisLabel(Theme.Opacity.textTertiary)
                ForEach(detail.children, id: \.id) { c in
                    Text("\(c.kind.label) · \(c.title) — \(c.state.label.lowercased())").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                }
            }
            if developer { GraphDiagnostics(detail: detail) }
        }
    }
}

private struct GraphNodeRow: View {
    let step: TaskStepRecord
    let provider: String?
    let expanded: Bool
    let onToggle: () -> Void

    private var tint: Color {
        switch step.state {
        case .passed: Theme.Palette.mint
        case .failed: Theme.Palette.coral
        case .running, .verifying: Theme.Palette.accent
        case .waitingForApproval, .interrupted: Theme.Palette.amber
        default: Color.jarvisTertiary
        }
    }
    private var symbol: String {
        switch step.state {
        case .passed: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .running: "circle.dotted.circle"; case .verifying: "checkmark.seal"
        case .waitingForApproval: "hand.raised.fill"; case .interrupted: "bolt.slash"; case .cancelled: "stop.circle"; case .skipped: "minus.circle"; default: "circle"
        }
    }
    /// "Coding · OpenCode Free · space-bunny-free" — the ROLE first; the provider is shown as the engine behind it, never as the agent itself.
    private var who: String { [step.role?.label ?? "Approval", provider].compactMap { $0 }.joined(separator: " · ") }
    private var duration: String? {
        guard let a = step.startedAt else { return nil }
        let s = (step.finishedAt ?? Date()).timeIntervalSince(a)
        return s < 1 ? "<1 s" : s < 120 ? "\(Int(s)) s" : "\(Int(s / 60)) min"
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 14).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(who).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color.jarvisPrimary).lineLimit(1)
                        if step.optional { Tag(text: "OPTIONAL") }
                        if step.revision > 0 { Tag(text: "REV \(step.revision)") }
                    }
                    Text(step.title).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary).lineLimit(2)
                    Text("validates: \(step.validation.rawValue)\(step.dependsOn.isEmpty ? "" : " · after \(step.dependsOn.joined(separator: ", "))")\(step.attempts > 1 ? " · \(step.attempts) attempts" : "")\(duration.map { " · \($0)" } ?? "")")
                        .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(2)
                    if let e = step.validationEvidence, !e.isEmpty, step.state.isTerminal {
                        Text(e.split(separator: "\n").first.map(String.init) ?? e).font(Theme.Typography.caption).foregroundStyle(step.state == .failed ? Theme.Palette.coral : Color.jarvisSecondary).lineLimit(2)
                    } else if let why = step.failureReason, step.state == .failed {
                        Text(why).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.coral).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Text(step.state == .pending || step.state == .ready ? "WAITING" : step.state.label).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(who). \(step.title), \(step.state.label.lowercased())\(step.optional ? ", optional" : "")")
        .accessibilityHint(expanded ? "Hide the artifacts and routing reason" : "Show the artifacts and routing reason")
    }
}

/// One node drilled open: why this provider, what it produced (sanitized), how it was validated.
private struct NodeDetail: View {
    let step: TaskStepRecord
    let detail: OrchestrationDetail
    let developer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(detail.decisions(node: step.key)) { d in
                Label(d.reasonText, systemImage: "arrow.triangle.branch").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).fixedSize(horizontal: false, vertical: true)
                if let f = d.failureClass, d.outcome != "passed" { Text("Failure class: \(NodeFailureClass(rawValue: f)?.label ?? f)").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.coral) }
                if let e = d.escalationReason, let r = EscalationReason(rawValue: e) { Text("Escalated because \(r.label).").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
            }
            ForEach(detail.artifacts(node: step.key)) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Tag(text: a.kind.label.uppercased())
                        Tag(text: a.trust.label.uppercased(), tint: a.trust == .externalUntrusted || a.trust == .modelGenerated ? Theme.Palette.amber : Theme.Palette.mint)
                        if a.status != .valid { Tag(text: a.status.rawValue.uppercased(), tint: Theme.Palette.coral) }
                        Text("\(a.chars) chars").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                    }
                    Text(a.validation).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                    Text(String(a.content.prefix(700))).font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary).lineLimit(10).textSelection(.enabled)
                    if !a.injectionFlags.isEmpty { Text("Contains instruction-shaped text (\(a.injectionFlags.joined(separator: ", "))) — kept as untrusted data.").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
                }
            }
            if detail.artifacts(node: step.key).isEmpty, detail.decisions(node: step.key).isEmpty {
                Text(step.state == .pending ? "Not started yet." : "No artifact for this node.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
        .padding(.leading, 22)
        .accessibilityElement(children: .contain)
    }
}

/// Developer diagnostics (Settings → Show Developer Controls): routing decisions with sizes, context stats, the graph header. No chain-of-thought exists to show.
private struct GraphDiagnostics: View {
    let detail: OrchestrationDetail
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DIAGNOSTICS").jarvisLabel(Theme.Opacity.textTertiary)
            if let g = detail.graph {
                Text("template \(g.template) · planner \(g.planner)\(g.plannerMS.map { " · \(Int($0)) ms" } ?? "")\(g.plannerChars.map { " · prompt \($0) chars" } ?? "") · revisions \(g.revisions)")
                    .font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary)
            }
            ForEach(detail.decisions) { d in
                Text("\(d.role?.label ?? "Planner") \(d.nodeKey ?? "-") → \(d.engine ?? "—")\(d.model.map { "/\($0)" } ?? "") · \(d.outcome ?? "—") · ctx \(d.contextChars ?? 0) ch · handoff \(d.handoffChars ?? 0) ch · mem \(d.memoryItems ?? 0) · art \(d.artifactCount ?? 0) · \(Int(d.runMS ?? 0)) ms · \(d.costClass ?? "—")")
                    .font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary).lineLimit(2)
            }
        }
    }
}
