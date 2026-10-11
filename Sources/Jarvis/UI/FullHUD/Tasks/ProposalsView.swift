import SwiftUI

// MARK: - Suggestions & approvals (V0.5): passive, understandable, never auto-approved

/// Pending proposals + recorded findings, shown at the top of the Tasks screen. Only actions that really work are offered:
/// Approve / Deny / Dismiss (proposals) and "Propose" (turn a recorded finding into a proposal, by the user's own click).
struct ProposalsGroup: View {
    @Environment(AppContext.self) private var app
    @State private var showFindings = false

    var body: some View {
        let engine = app.opportunities
        let pending = engine.pending
        let recorded = engine.recorded
        if app.preferences.showProposals, !(pending.isEmpty && recorded.isEmpty) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.s) {
                    Text("SUGGESTIONS · \(app.preferences.autonomyMode.label.uppercased())").jarvisLabel(Theme.Opacity.textTertiary).accessibilityAddTraits(.isHeader)
                    Spacer()
                }
                ForEach(pending) { p in ProposalCard(proposal: p) }
                if !recorded.isEmpty {
                    Button { withAnimation(app.preferences.effectiveReduceMotion ? nil : .easeOut(duration: Theme.Duration.fast)) { showFindings.toggle() } } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: showFindings ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
                            Text("\(recorded.count) RECORDED FINDING\(recorded.count == 1 ? "" : "S") (NO ACTION TAKEN)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(Color.jarvisSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(recorded.count) recorded findings, \(showFindings ? "shown" : "hidden")")
                    if showFindings { ForEach(recorded) { o in RecordedFindingRow(opportunity: o) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("proposals.group")
        }
    }
}

struct ProposalCard: View {
    @Environment(AppContext.self) private var app
    let proposal: ProposalRecord

    private var opportunity: OpportunityRecord? { app.opportunities.opportunity(proposal.opportunityID) }
    private var unsupported: [String] { opportunity.map { ProposalService.unsupportedReasons($0, action: proposal.proposedAction) } ?? [] }
    private var accent: Color { proposal.critical ? Theme.Palette.coral : Theme.Palette.violet }
    private var project: String { (proposal.projectRoot as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: proposal.critical ? "exclamationmark.shield.fill" : "lightbulb.fill").foregroundStyle(accent).accessibilityHidden(true)
                Text(proposal.title).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary).lineLimit(3).multilineTextAlignment(.leading)
                Spacer(minLength: Theme.Spacing.s)
                if proposal.critical { Tag(text: "CRITICAL · EXPLICIT APPROVAL") } else { Tag(text: "PROPOSAL") }
            }
            Text("Project: \(project)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)

            section("WHY JARVIS NOTICED", proposal.summary.isEmpty ? proposal.reason : proposal.summary)
            if !proposal.evidence.isEmpty { section("EVIDENCE", proposal.evidence) }
            section("PROPOSED ACTION", proposal.proposedAction.goal)
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                fact("SCOPE", scopeText)
                fact("RISK", proposal.risk.rawValue.capitalized)
                fact("DESIGN CHANGE", proposal.designImpact == .none ? "None expected" : "Yes — your decision")
                fact("REVERSIBLE", proposal.reversibility == .reversible ? "Yes" : proposal.reversibility == .partiallyReversible ? "Partly" : "No")
            }
            section("EXPECTED BENEFIT", proposal.expectedBenefit)
            section("HOW IT WILL BE VALIDATED", proposal.validationPlan)

            if proposal.critical {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WHAT THIS MEANS").jarvisLabel(Theme.Opacity.textTertiary)
                    Text("This would affect something outside the project folder or cannot be undone. If you deny it, nothing happens.\(proposal.reason.isEmpty ? "" : " " + proposal.reason)")
                        .font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !unsupported.isEmpty {
                Label("JARVIS cannot perform this in this version (\(unsupported.joined(separator: ", "))). Approving it will not make it possible; nothing would be executed.", systemImage: "info.circle")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("If approved, JARVIS creates a normal task: it plans, validates and runs it within exactly this scope and reports back.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }

            // Equal weight, nothing pre-selected, no dark patterns.
            HStack(spacing: Theme.Spacing.s) {
                Button("APPROVE") { Task { await app.proposalService.approve(proposal.id, source: .hud) } }.buttonStyle(.hudSecondary).accessibilityLabel("Approve: \(proposal.title)")
                    .accessibilityIdentifier("proposal.approve.\(proposal.id.uuidString.prefix(8))")
                Button("DENY") { app.proposalService.deny(proposal.id, source: .hud) }.buttonStyle(.hudSecondary).accessibilityLabel("Deny: \(proposal.title)")
                    .accessibilityIdentifier("proposal.deny.\(proposal.id.uuidString.prefix(8))")
                Button("DISMISS") { app.proposalService.dismiss(proposal.id, source: .hud) }.buttonStyle(.hudSecondary).accessibilityLabel("Dismiss: \(proposal.title)")
                    .accessibilityIdentifier("proposal.dismiss.\(proposal.id.uuidString.prefix(8))")
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.Spacing.m)
        .background(HUDCardBackground(accent: accent, raised: proposal.critical))
        .overlay(alignment: .leading) { if proposal.critical { Rectangle().fill(Theme.Palette.coral).frame(width: 3).accessibilityHidden(true) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(proposal.critical ? "Critical approval needed" : "Suggestion"): \(proposal.title). Risk \(proposal.risk.rawValue).")
        .accessibilityIdentifier("proposal.card.\(proposal.id.uuidString.prefix(8))")
    }

    private var scopeText: String {
        let a = proposal.proposedAction
        var s = a.scope.testFilesOnly ? "Test files only" : "Project files"
        if !a.expectedFiles.isEmpty { s += ": " + a.expectedFiles.prefix(3).joined(separator: ", ") }
        return s + " · max \(a.scope.maxChangedFiles) file\(a.scope.maxChangedFiles == 1 ? "" : "s")"
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).jarvisLabel(Theme.Opacity.textTertiary)
            Text(text).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).jarvisLabel(Theme.Opacity.textTertiary)
            Text(value).font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RecordedFindingRow: View {
    @Environment(AppContext.self) private var app
    let opportunity: OpportunityRecord

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Color.jarvisTertiary).frame(width: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(opportunity.title).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).lineLimit(2)
                Text("\(opportunity.category.label) · \(opportunity.policyReasons.prefix(3).joined(separator: ", "))").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if opportunity.proposedAction != nil {
                Button("PROPOSE") { app.proposalService.promote(opportunity.id, source: .hud) }.buttonStyle(.hudSecondary).fixedSize()
                    .accessibilityLabel("Turn this finding into a proposal: \(opportunity.title)")
            }
        }
        .padding(Theme.Spacing.s)
        .background(HUDCardBackground(cornerRadius: Theme.Radius.s, accent: Color.jarvisTertiary))
        .accessibilityElement(children: .contain)
    }
}
