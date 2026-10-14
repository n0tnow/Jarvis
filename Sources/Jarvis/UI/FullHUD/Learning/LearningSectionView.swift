import SwiftUI

// MARK: - Learning screen (V0.14): what JARVIS noticed in its own work, what it proposes, and what is active — with the evidence. Learning is never authority.

struct LearningSectionView: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let model = app.learningModel
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                header(model)
                if let m = model.message { LearningMessageBar(text: m) { model.message = nil } }
                if !model.isEnabled { disabled } else {
                    if !model.pending.isEmpty { PendingCard(model: model) }
                    Picker("", selection: Bindable(model).tab) { ForEach(LearningViewModel.Tab.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Learning view").accessibilityIdentifier("learning.tabs")
                    if let c = model.selectedCandidate { CandidateDetail(model: model, c: c) }
                    switch model.tab {
                    case .insights: InsightsList(model: model)
                    case .candidates: CandidateList(model: model)
                    case .rules: RulesList(model: model)
                    case .skills: SkillsList(model: model)
                    case .gaps: GapsList(model: model)
                    case .proposals: ProposalsList(model: model)
                    case .history: HistoryList(model: model)
                    }
                }
            }
            .frame(maxWidth: 860)
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("learning.section")
        .onAppear { model.refresh() }
        .onChange(of: app.learning.revision) { _, _ in model.refresh() }
        .onChange(of: app.adaptiveDecisions.revision) { _, _ in model.refresh() }
        .onChange(of: app.selfImprovement.revision) { _, _ in model.refresh() }
    }

    private func header(_ model: LearningViewModel) -> some View {
        HUDCard("Learning") {
            Tag(text: "LEARNING IS NOT AUTHORITY", tint: Theme.Palette.violet)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("JARVIS looks at its own finished work and writes down what repeats — failures, workflows that keep succeeding, tools it keeps working around. A candidate needs several independent events, shows its evidence, and does nothing until you activate it.")
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                HStack {
                    Text("Level: \(model.level.label) — \(model.level.explanation)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                    Spacer(minLength: 0)
                    Button("LOOK AT RECENT WORK") { Task { await model.extractNow() } }.buttonStyle(.hudSecondary).fixedSize().disabled(model.busy)
                        .accessibilityHint("Reads finished tasks and experiments once; nothing runs by itself")
                }
                Text("A rule can only ADD a requirement (a test, a review, a warning). It can never approve, grant, install, delete, send or weaken a check. \(model.signals) signal(s) recorded.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }
    private var disabled: some View {
        HUDCard("Adaptive learning is off") { Text("Nothing is learned or proposed. Turn it on in Settings → Adaptive learning.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary) }
    }
}

private struct LearningMessageBar: View {
    let text: String; let dismiss: () -> Void
    var body: some View {
        HStack {
            Text(text).font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary)
            Spacer()
            Button("OK", action: dismiss).buttonStyle(.hudSecondary).fixedSize()
        }
        .padding(Theme.Spacing.s).background(HUDCardBackground(accent: Theme.Palette.amber))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Waiting for a decision (HUD buttons are the ONLY way to decide)

private struct PendingCard: View {
    let model: LearningViewModel
    var body: some View {
        HUDCard("Waiting for your decision", trailing: { Tag(text: "BUTTONS ONLY", tint: Theme.Palette.amber) }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(model.pending) { q in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(q.summary).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary); Tag(text: q.risk.rawValue.uppercased(), tint: q.risk >= .high ? Theme.Palette.coral : Theme.Palette.amber); Spacer(minLength: 0) }
                        Text(q.detail).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(8)
                        HStack {
                            Button("APPROVE") { Task { await model.approve(q) } }.buttonStyle(.hudPrimary).fixedSize().accessibilityIdentifier("learning.approve")
                            Button("DECLINE") { model.deny(q) }.buttonStyle(.hudSecondary).fixedSize().accessibilityIdentifier("learning.decline")
                            Text("Saying “yes” does not approve this.").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Lists

private func statusTint(_ s: LearningStatus) -> Color {
    switch s { case .active: Theme.Palette.mint; case .rejected, .retired, .superseded: Theme.Palette.coral; case .observed: Color.jarvisTertiary; default: Theme.Palette.amber }
}

private struct CandidateRow: View {
    let model: LearningViewModel; let c: LearningCandidate
    var body: some View {
        Button { model.selected = c.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(c.title).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary).lineLimit(2)
                    Tag(text: c.status.label, tint: statusTint(c.status)); Tag(text: c.kind.label.uppercased())
                    Spacer(minLength: 0)
                    Text("\(c.occurrenceCount)× · \(String(format: "%.0f", c.confidence * 100)) %").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
                }
                Text(c.summary).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(2)
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("learning.candidate")
        .accessibilityLabel("\(c.kind.label): \(c.title), \(c.status.label.lowercased()), \(c.occurrenceCount) events")
    }
}

private struct EmptyCard: View {
    let title: String; let text: String
    var body: some View { HUDCard(title) { Text(text).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary) } }
}

private struct InsightsList: View {
    let model: LearningViewModel
    var body: some View {
        if model.insights.isEmpty { EmptyCard(title: "Nothing worth keeping yet", text: "A pattern needs three independent occurrences (separate tasks). Until then JARVIS only counts signals.") }
        else { HUDCard("Insights", trailing: { Text("\(model.insights.count)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }) { VStack(alignment: .leading, spacing: Theme.Spacing.xs) { ForEach(model.insights) { CandidateRow(model: model, c: $0) } } } }
    }
}
private struct CandidateList: View {
    let model: LearningViewModel
    var body: some View {
        if model.candidates.isEmpty { EmptyCard(title: "No candidate rules or workflows", text: "Repeated failures, repeated successful workflows and repeated corrections become candidates here. Nothing is active until you approve it.") }
        else { HUDCard("Candidate rules, workflows and routing") { VStack(alignment: .leading, spacing: Theme.Spacing.xs) { ForEach(model.candidates) { CandidateRow(model: model, c: $0) } } } }
    }
}
private struct GapsList: View {
    let model: LearningViewModel
    var body: some View {
        if model.gaps.isEmpty { EmptyCard(title: "No capability gaps", text: "A gap is recorded when JARVIS keeps working around a missing structured tool (for example clicking through an app). A gap is evidence, never permission to install anything.") }
        else { HUDCard("Capability gaps") { VStack(alignment: .leading, spacing: Theme.Spacing.xs) { ForEach(model.gaps) { CandidateRow(model: model, c: $0) } } } }
    }
}

private struct RulesList: View {
    let model: LearningViewModel
    var body: some View {
        if model.rules.isEmpty { EmptyCard(title: "No active rules", text: "A rule appears here after a candidate passed its test and you approved it. Every rule can be disabled, reverted or retired.") }
        else {
            HUDCard("Rules") {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(model.rules) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(r.title).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary).lineLimit(2); Tag(text: "\(r.status.label) v\(r.version)", tint: statusTint(r.status)); Spacer(minLength: 0) }
                            Text(model.ruleText(r)).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                            Text("\(r.origin) · scope \(r.scope.label) · worked \(r.successCount)× / failed \(r.failureCount)× · last used \(r.lastUsedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never")")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
                            HStack {
                                if r.status == .active { Button("DISABLE") { model.disable(r) }.buttonStyle(.hudSecondary).fixedSize() } else { Button("ENABLE") { model.enable(r) }.buttonStyle(.hudSecondary).fixedSize() }
                                if r.version > 1 { Button("REVERT") { model.revert(r) }.buttonStyle(.hudSecondary).fixedSize() }
                                Button("RETIRE") { model.retire(r) }.buttonStyle(.hudSecondary).fixedSize()
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

private struct SkillsList: View {
    let model: LearningViewModel
    var body: some View {
        HUDCard("Skills", trailing: { Text("reusable, validated workflows").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(model.skills) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(s.name).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary); Tag(text: s.status.label, tint: s.status == .active ? Theme.Palette.mint : Theme.Palette.amber); Tag(text: s.builtIn ? "BUILT IN" : "LEARNED"); Spacer(minLength: 0) }
                        Text(s.description).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(2)
                        Text("\(s.origin) · \(s.successCount)✓ \(s.failureCount)✗ · needs \(s.requiredCapabilities.joined(separator: ", ")) · still runs through the normal engine and approvals").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary).lineLimit(2)
                        if !s.builtIn { HStack { if s.status == .active { Button("DISABLE") { model.setSkill(s, .disabled) }.buttonStyle(.hudSecondary).fixedSize() } else if s.status != .retired { Button("ENABLE") { model.setSkill(s, .active) }.buttonStyle(.hudSecondary).fixedSize() }; Button("RETIRE") { model.setSkill(s, .retired) }.buttonStyle(.hudSecondary).fixedSize() } }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct ProposalsList: View {
    let model: LearningViewModel
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            HUDCard("Self-improvement", trailing: { Tag(text: model.level.label.uppercased(), tint: Theme.Palette.violet) }) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(model.level.explanation).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                    Text("JARVIS never edits its own source because it found an idea. At the highest level, after your explicit approval, a change becomes an ordinary development task: analysis, coding, tests and an independent review, from a recorded checkpoint on a clean tree. A failed change is never promoted. There is no level above this one.")
                        .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                }
            }
            if model.improvementCandidates.isEmpty && model.proposals.isEmpty { EmptyCard(title: "Nothing proposed", text: "A proposal appears when repeated evidence points at a concrete improvement to JARVIS itself.") }
            ForEach(model.improvementCandidates) { c in
                HUDCard("Candidate improvement") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary)
                        Text(c.summary).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                        Button("WRITE AS A PROPOSAL") { model.writeProposal(c.id) }.buttonStyle(.hudSecondary).fixedSize().disabled(model.level < .propose).accessibilityHint(model.level < .propose ? "Needs the Propose level in Settings" : "Writes text only; changes nothing")
                    }
                }
            }
            ForEach(model.proposals) { p in
                HUDCard(p.title, trailing: { Tag(text: p.status.rawValue.uppercased(), tint: p.status == .applied ? Theme.Palette.mint : (p.status == .failed ? Theme.Palette.coral : Theme.Palette.amber)) }) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(model.explanation(p)).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                        if let r = p.result { Text(r).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary) }
                        if p.status == .proposed { Button("ASK TO APPLY") { Task { await model.requestApply(p) } }.buttonStyle(.hudPrimary).fixedSize().disabled(model.level < .approvedSelfImprovement)
                            .accessibilityHint(model.level < .approvedSelfImprovement ? "Needs the highest level in Settings" : "Creates a request you must approve") }
                    }
                }
            }
        }
    }
}

private struct HistoryList: View {
    let model: LearningViewModel
    var body: some View {
        if model.history.isEmpty { EmptyCard(title: "No history yet", text: "Every candidate, test, decision and activation is recorded here with who decided it.") }
        else {
            HUDCard("History") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.history) { h in
                        Text("\(h.at.formatted(date: .abbreviated, time: .shortened)) · \(h.kind) · \(h.detail) · \(h.by)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.jarvisSecondary).lineLimit(2)
                    }
                }
            }
        }
    }
}

// MARK: Candidate detail

private struct CandidateDetail: View {
    let model: LearningViewModel; let c: LearningCandidate
    var body: some View {
        HUDCard(c.title, trailing: { Button("CLOSE") { model.selected = nil }.buttonStyle(.hudSecondary).fixedSize() }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                row("What JARVIS noticed", c.summary)
                row("How often", "\(c.occurrenceCount) independent event(s) · confidence \(String(format: "%.0f", c.confidence * 100)) % · last seen \(c.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                row("What JARVIS proposes", c.proposedEffect)
                if let r = c.payload.rule { row("The rule (data, not code)", RuleEngine.describe(r)) }
                if let w = c.payload.workflow { row("The workflow", w.signature.replacingOccurrences(of: ">", with: " → ")) }
                if let g = c.payload.gap { row("Options compared", g.options.sorted { $0.rank < $1.rank }.map { "\($0.rank). \($0.architecture) — \($0.rationale)" }.joined(separator: "\n")) }
                row("Risk", c.risk.rawValue.capitalized)
                row("Validation", c.validationRequirement)
                row("Needed to activate", c.promotionRequirement)
                row("Scope", c.scope.label)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EVIDENCE").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
                    ForEach(Array(c.evidence.prefix(8).enumerated()), id: \.offset) { _, e in
                        Text("\(e.kind.rawValue) \(String(e.sourceID.prefix(8))) · \(e.at.formatted(date: .abbreviated, time: .shortened)) · \(e.note)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                    }
                }
                HStack {
                    if [.candidate, .testing].contains(c.status), model.level >= .experiment { Button("TEST") { Task { await model.test(c.id) } }.buttonStyle(.hudSecondary).fixedSize().accessibilityIdentifier("learning.test") }
                    if [.candidate, .validated].contains(c.status) { Button("PROPOSE FOR ACTIVATION") { Task { await model.propose(c.id) } }.buttonStyle(.hudPrimary).fixedSize().accessibilityIdentifier("learning.propose") }
                    if !c.status.isTerminal, c.status != .active { Button("REJECT") { model.reject(c.id) }.buttonStyle(.hudDestructive).fixedSize().accessibilityIdentifier("learning.reject") }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
            Text(v.isEmpty ? "—" : v).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
