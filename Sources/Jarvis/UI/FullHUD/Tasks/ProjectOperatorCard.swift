import SwiftUI

// MARK: - Project continuity card (V0.13): where the project stands, what "continue" would do, and the one button that does it.
// Everything shown is derived from current project truth, tasks, the last checkpoint and memory; nothing here is a model's opinion. Reading happens when the card appears,
// when a task finishes and on Refresh — never on a timer.

struct ProjectOperatorCard: View {
    @Environment(AppContext.self) private var app
    var body: some View {
        let m = app.operatorModel
        if !app.preferences.projectRoot.isEmpty, app.preferences.projectContinuationEnabled {
            HUDCard("Project continuity", trailing: {
                HStack(spacing: Theme.Spacing.s) {
                    Button("REFRESH") { Task { await m.refresh() } }.buttonStyle(.hudSecondary).fixedSize().disabled(m.busy).accessibilityIdentifier("operator.refresh")
                    Button("CONTINUE") { Task { await m.continueProject() } }.buttonStyle(.hudPrimary).fixedSize().disabled(m.busy || (m.view?.running.isEmpty == false)).accessibilityIdentifier("operator.continue")
                        .help("Same as saying “continue”: one bounded session. It grants no new permission; approvals stay in the HUD.")
                }
            }) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if let v = m.view { content(v, m) } else { Text(m.busy ? "Reading the project…" : "Not read yet.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
                    if let a = m.lastAnswer { Text(a).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).textSelection(.enabled) }
                }
            }
            .task(id: "\(app.taskEngine.revision)|\(app.preferences.projectRoot)") { await m.refresh() }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func content(_ v: ProjectContinuityView, _ m: ProjectOperatorViewModel) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(v.name).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary)
            Tag(text: v.projectType.uppercased())
            if let ms = v.milestone { Text(ms).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(1) }
        }
        line("Git", ContinuityStatus.gitLine(v.git, .en) ?? "Not a Git repository.")
        if let u = v.unity { line("Unity", "\(u.version ?? "?") · \(u.renderPipeline) · \(u.sceneCount) scene(s)\(u.editor.map { " · editor \($0.lowercased())" } ?? "")") }
        if let sc = m.scene { sceneRows(sc) }
        if let c = v.checkpoint { line("Checkpoint", "\(c.title) — \(c.outcome.lowercased()), \(ContinuityStatus.ago(c.createdAt, .en)) · \(c.validated.first ?? "")") }
        if !v.currentWork.isEmpty { line("Current", v.currentWork.joined(separator: " · ")) }
        if let t = v.recentCompleted.first { line("Last task", "“\(t.title)” — \(ContinuityStatus.ago(t.finishedAt ?? t.updatedAt, .en))") }
        if !v.openIssues.isEmpty { line("Open issues", v.openIssues.prefix(3).joined(separator: " · ")) }
        if let n = v.candidates.first { line("Next", "\(n.title) (\(n.source.rawValue))") }
        if !v.blockers.isEmpty { Text(v.blockers.joined(separator: " · ")).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
        if m.report.hasDrift {
            Text("Changed outside JARVIS since the last checkpoint: \(m.report.changedPaths.prefix(4).joined(separator: ", "))\(m.report.headMoved ? " · Git HEAD moved" : "")")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber)
        }
        Text("A session is bounded: \(m.bounds.summary).").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
        if app.preferences.showDeveloperControls, let d = m.diagnostics {
            Text("Truth sources: \(d.sources.joined(separator: ", ")) · decision: \(d.decision)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
            ForEach(d.reconciliation, id: \.self) { Text($0).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary) }
        }
    }

    /// The open scene: headline numbers + where they come from. A remembered reading is dimmed and says how old it is — it is never presented as the present.
    @ViewBuilder private func sceneRows(_ sc: UnitySceneFacts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text("SCENE").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.jarvisTertiary).frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(sc.line).font(Theme.Typography.caption).foregroundStyle(sc.live ? Color.jarvisSecondary : Color.jarvisTertiary).lineLimit(2).accessibilityIdentifier("operator.scene")
                Text(sc.freshness()).font(.system(size: 10, design: .monospaced)).foregroundStyle(sc.live ? Color.jarvisTertiary : Theme.Palette.amber).accessibilityIdentifier("operator.scene.freshness")
            }
        }
        if !sc.warnings.isEmpty { Text("Scene: " + sc.warnings.joined(separator: " · ")).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
    }

    private func line(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.jarvisTertiary).frame(width: 82, alignment: .leading)
            Text(text).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(2)
        }
    }
}
