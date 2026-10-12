import SwiftUI

// MARK: - Research screen (V0.9): what JARVIS looked up, why it believes it, what it may do next

struct ResearchSectionView: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let model = app.researchModel
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                header(model)
                if let m = model.message { MessageBar(text: m) { model.message = nil } }
                if model.sessions.isEmpty { emptyState } else { SessionsList(model: model) }
                if let d = model.detail { ResearchDetailView(detail: d, model: model) }
                AcquisitionsGroup(model: model)
            }
            .frame(maxWidth: 860)
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("research.section")
        .onAppear { model.refresh() }
        .onChange(of: app.taskEngine.revision) { _, _ in model.refreshSoon() }
    }

    private func header(_ model: ResearchViewModel) -> some View {
        HUDCard("Research") {
            Tag(text: "READ-ONLY", tint: Theme.Palette.mint)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Ask JARVIS to research something — by typing or by voice (“hamam oyunu için ücretsiz terlik fırlatma animasyonu araştır”, “research this Unity error”).")
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                Text("Research only reads public pages and writes a cited report. Downloading is a separate task, importing into a project is another one with its own approval, and JARVIS never signs in, accepts terms, claims an asset or buys anything.")
                    .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }

    private var emptyState: some View {
        HUDCard("No research yet") {
            Text("Nothing has been researched. Web research never starts by itself — only when you ask.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
        }
    }
}

private struct MessageBar: View {
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

// MARK: Sessions

private struct SessionsList: View {
    @Environment(AppContext.self) private var app
    let model: ResearchViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("RESEARCH").jarvisLabel(Theme.Opacity.textTertiary).accessibilityAddTraits(.isHeader)
            ForEach(model.sessions) { row in
                let live = app.taskEngine.view(row.id)
                let selected = model.selectedID == row.id
                Button { model.selectedID = row.id } label: {
                    HStack(alignment: .top, spacing: Theme.Spacing.s) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.goal).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary).lineLimit(2).multilineTextAlignment(.leading)
                            HStack(spacing: Theme.Spacing.s) {
                                Tag(text: row.type.label.uppercased())
                                Tag(text: (live.map { $0.task.activity.isEmpty ? row.status.label : $0.task.activity } ?? row.status.label).uppercased(), tint: tint(row.status))
                                if let m = row.meter { Text("\(m.sources) sources · \(m.queries) queries").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
                            }
                        }
                        Spacer(minLength: 0)
                        if let live, live.task.state.isStoppable, row.status.isTerminal == false {
                            Button("STOP") { model.stop(row.id) }.buttonStyle(.hudSecondary).fixedSize().accessibilityLabel("Stop this research")
                        }
                        if row.status == .interrupted { Button("RESUME") { model.resume(row.id) }.buttonStyle(.hudSecondary).fixedSize().accessibilityLabel("Resume this research") }
                    }
                    .padding(Theme.Spacing.s)
                    .background(HUDCardBackground(accent: selected ? Theme.Palette.accent : Color.white.opacity(0.3), raised: selected))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint("Shows the sources, evidence and candidates of this research")
            }
        }
    }
    private func tint(_ s: ResearchStatus) -> Color { switch s { case .completed: Theme.Palette.mint; case .failed: Theme.Palette.coral; case .cancelled, .interrupted: Theme.Palette.amber; default: Theme.Palette.accent } }
}

// MARK: Detail

private struct ResearchDetailView: View {
    @Environment(AppContext.self) private var app
    let detail: ResearchViewModel.Detail
    let model: ResearchViewModel

    var body: some View {
        let order = sourceNumbers
        VStack(spacing: Theme.Spacing.m) {
            recommendation
            if !detail.candidates.isEmpty { candidates }
            facts(order)
            if !detail.claims.filter({ $0.status == .contradicted }).isEmpty || (reportContradictions.isEmpty == false) { contradictions }
            uncertainties
            sources(order)
            queries
        }
    }

    private var sourceNumbers: [UUID: Int] {
        var m: [UUID: Int] = [:]
        for (i, s) in detail.sources.filter({ $0.method != .searchSnippet }).enumerated() { m[s.id] = i + 1 }
        return m
    }
    private func cite(_ ids: [UUID], _ order: [UUID: Int]) -> String { ids.compactMap { order[$0] }.sorted().map { "[S\($0)]" }.joined() }

    private var reportContradictions: [String] {
        guard let md = detail.markdown, let r = md.range(of: "## Contradictions\n") else { return [] }
        let tail = md[r.upperBound...]
        let block = tail.components(separatedBy: "\n## ").first ?? ""
        return block.split(separator: "\n").map { String($0).replacingOccurrences(of: "- ", with: "") }.filter { !$0.isEmpty }
    }

    private var recommendation: some View {
        HUDCard("Recommendation") {
            Tag(text: detail.row.status.label.uppercased(), tint: detail.row.status == .completed ? Theme.Palette.mint : Theme.Palette.amber)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let md = detail.markdown, let r = md.range(of: "## Recommendation\n\n") {
                    let text = md[r.upperBound...].components(separatedBy: "\n\n*Next safe action:*").first ?? ""
                    Text(text).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).textSelection(.enabled)
                    if let n = md.range(of: "*Next safe action:* ") { Text("Next safe action: " + (md[n.upperBound...].components(separatedBy: "\n").first ?? "")).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary) }
                } else {
                    Text(detail.row.status.isTerminal ? "No report was produced (\(detail.row.status.label))." : "The report appears here when the research is finished.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                }
                Text(detail.row.constraints.summary.isEmpty ? "Constraints: none" : "Constraints: " + detail.row.constraints.summary.joined(separator: " · ")).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Candidates

    private var candidates: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("CANDIDATES · FACT, ASSESSMENT AND RECOMMENDATION ARE KEPT APART").jarvisLabel(Theme.Opacity.textTertiary).accessibilityAddTraits(.isHeader)
            ForEach(detail.candidates.sorted { ($0.rank == 0 ? 999 : $0.rank) < ($1.rank == 0 ? 999 : $1.rank) }) { c in CandidateCard(candidate: c, detail: detail, model: model) }
        }
    }

    // MARK: Facts etc.

    private func facts(_ order: [UUID: Int]) -> some View {
        let facts = detail.claims.filter { $0.epistemic == .fact && $0.kind != .accountRequirement }
        let assessments = detail.claims.filter { $0.epistemic == .assessment }
        return Group {
            if !facts.isEmpty {
                HUDCard("Facts · each cites its source") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(facts) { c in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(c.subject.isEmpty ? "" : c.subject + ": ")\(c.statement) \(cite(c.evidence.map(\.sourceID), order))").font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).textSelection(.enabled)
                                HStack(spacing: Theme.Spacing.xs) {
                                    Tag(text: c.status.rawValue.uppercased(), tint: c.status == .verified ? Theme.Palette.mint : c.status == .contradicted ? Theme.Palette.coral : Theme.Palette.amber)
                                    Tag(text: c.freshness.rawValue.uppercased())
                                    if let e = c.evidence.first { Text("“\(e.excerpt)”").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(2) }
                                }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            if !assessments.isEmpty {
                HUDCard("Assessments · judgement, not fact") {
                    VStack(alignment: .leading, spacing: 3) { ForEach(assessments) { c in Text("\(c.subject): \(c.statement)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary) } }
                }
            }
        }
    }

    private var contradictions: some View {
        HUDCard("Contradictions") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(reportContradictions, id: \.self) { Text($0).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
                ForEach(detail.claims.filter { $0.status == .contradicted }) { Text("\($0.subject): \($0.statement)").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
            }
        }
    }

    private var uncertainties: some View {
        let items = detail.candidates.flatMap { c in c.unknowns.map { "\(c.name): \($0)" } }
        return Group {
            if !items.isEmpty {
                HUDCard("Unknown — not guessed") {
                    VStack(alignment: .leading, spacing: 2) { ForEach(items, id: \.self) { Text("UNKNOWN · \($0)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary) } }
                }
            }
        }
    }

    private func sources(_ order: [UUID: Int]) -> some View {
        let read = detail.sources.filter { $0.method != .searchSnippet }
        let snippets = detail.sources.filter { $0.method == .searchSnippet }
        return HUDCard("Sources · \(read.count) read, \(snippets.count) only listed", trailing: {
            Button(model.expandedSources ? "HIDE LISTED-ONLY" : "SHOW LISTED-ONLY") { model.expandedSources.toggle() }.buttonStyle(.hudSecondary).fixedSize()
        }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(read) { s in SourceRow(source: s, number: order[s.id], model: model, highlighted: model.highlightedSource == s.id) }
                if model.expandedSources {
                    ForEach(snippets) { s in SourceRow(source: s, number: nil, model: model, highlighted: false) }
                }
            }
        }
    }

    private var queries: some View {
        HUDCard("Searched") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(detail.queries) { q in
                    Text("\(q.text) · \(q.provider) · \(q.resultCount) result\(q.resultCount == 1 ? "" : "s")\(q.failure.map { " · FAILED: \($0)" } ?? "")").font(Theme.Typography.caption).foregroundStyle(q.failure == nil ? Color.jarvisSecondary : Theme.Palette.amber)
                }
            }
        }
    }
}

private struct SourceRow: View {
    let source: SourceRecord; let number: Int?; let model: ResearchViewModel; let highlighted: Bool
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Text(number.map { "S\($0)" } ?? "—").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.Palette.accent).frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title.isEmpty ? source.domain : source.title).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).lineLimit(2)
                HStack(spacing: Theme.Spacing.xs) {
                    Tag(text: source.type.label.uppercased())
                    Tag(text: source.official.rawValue.uppercased(), tint: source.official == .official ? Theme.Palette.mint : source.official == .community ? Theme.Palette.violet : Color.jarvisSecondary)
                    Tag(text: "TRUST \(source.trust)/5")
                    Tag(text: source.method == .searchSnippet ? "SNIPPET ONLY · NOT EVIDENCE" : source.method.rawValue.uppercased(), tint: source.method == .searchSnippet ? Theme.Palette.amber : Color.jarvisSecondary)
                    if !source.injectionFlags.isEmpty { Tag(text: "TRIED TO INSTRUCT THE AI · IGNORED", tint: Theme.Palette.coral) }
                    if source.authRequired { Tag(text: "LOGIN WALL", tint: Theme.Palette.amber) }
                }
                Text("\(source.domain) · retrieved \(source.retrievedAt.formatted(date: .abbreviated, time: .shortened))\(source.httpStatus.map { " · HTTP \($0)" } ?? "")").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                if let note = source.note { Text(note).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
            }
            Spacer(minLength: 0)
            Button("OPEN") { model.open(source.url) }.buttonStyle(.hudSecondary).fixedSize().accessibilityLabel("Open source \(source.title) in your browser")
        }
        .padding(Theme.Spacing.xs)
        .background(highlighted ? Theme.Palette.accent.opacity(0.12) : .clear)
        .accessibilityElement(children: .contain)
    }
}

private struct CandidateCard: View {
    let candidate: CandidateRecord
    let detail: ResearchViewModel.Detail
    let model: ResearchViewModel
    @Environment(AppContext.self) private var app

    private var acquisition: AcquisitionRecord? { detail.acquisitions.first { $0.candidateID == candidate.id } }

    var body: some View {
        let c = candidate
        HUDCard("\(c.rank == 0 ? "" : "#\(c.rank) · ")\(c.name)", trailing: {
            Tag(text: c.verdict == .undecided ? "NOT RANKED" : c.verdict.rawValue.uppercased(), tint: c.verdict == .preferred ? Theme.Palette.mint : c.verdict == .alternative ? Theme.Palette.accent : c.verdict == .notRecommended ? Theme.Palette.coral : Color.jarvisSecondary)
        }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                field("Source", c.url, mono: true)
                field("Publisher", c.publisher ?? "UNKNOWN")
                field("Price", c.price.label + (c.price.verifiedAt.map { " · verified \($0.formatted(date: .omitted, time: .shortened))" } ?? ""), tint: c.price.state == .freeVerified ? Theme.Palette.mint : c.price.state == .paidVerified ? Theme.Palette.coral : Theme.Palette.amber)
                field("License", (c.license.identifier ?? c.license.state.rawValue) + (c.license.needsReview ? " · NEEDS REVIEW" : ""), tint: c.license.allowsAutomaticAcquisition ? Theme.Palette.mint : Theme.Palette.amber)
                field("Unity", "\(c.compatibility.unityVersion.rawValue)\(c.meta.unityVersions.map { " (listing: \($0))" } ?? "")")
                field("URP / pipeline", "\(c.compatibility.renderPipeline.rawValue)\(c.meta.pipelines.isEmpty ? "" : " (listing: \(c.meta.pipelines.joined(separator: ", ")))")")
                field("Format", c.meta.format.isEmpty ? "UNKNOWN" : c.meta.format.joined(separator: ", "))
                field("Style fit", c.styleFit.map { "\($0)  ·  MODEL ASSESSMENT, not a fact" } ?? "not assessed")
                field("Account required", c.accountRequired.rawValue.uppercased())
                field("Acquisition", c.acquisition.rawValue)
                if !c.verdictReasons.isEmpty { Text("Why: " + c.verdictReasons.joined(separator: "; ")).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary) }
                if !c.compatibility.reasons.isEmpty { Text("Compatibility: " + c.compatibility.reasons.joined(separator: "; ")).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
                if !c.unknowns.isEmpty { Text("UNKNOWN: " + c.unknowns.joined(separator: "; ")).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
                if !c.factors.isEmpty {
                    Text("Score \(String(format: "%.2f", c.score)) = " + c.factors.map { "\($0.name) \(String(format: "%.0f%%", $0.value * 100))×\(String(format: "%.0f%%", $0.weight * 100))" }.joined(separator: " · ")).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                }
                HStack(spacing: Theme.Spacing.s) {
                    Button("OPEN LISTING") { model.open(c.url) }.buttonStyle(.hudSecondary).fixedSize().accessibilityLabel("Open the listing of \(c.name) in your browser")
                    if c.acquisition == .publicDirectDownload, c.downloadURL != nil, acquisition == nil {
                        Button("DOWNLOAD TO QUARANTINE") { model.requestDownload(c) }.buttonStyle(.hudSecondary).fixedSize()
                            .accessibilityLabel("Download \(c.name) into the quarantine")
                            .accessibilityHint("Re-verifies price and licence, may ask you, and imports nothing")
                    } else if c.acquisition == .accountRequiredFree || c.acquisition == .marketplaceClaim || c.acquisition == .paidPurchase {
                        Text(c.acquisition == .paidPurchase ? "PAID — JARVIS never purchases" : "NEEDS AN ACCOUNT ACTION — do it yourself in the listing").font(Theme.Typography.label).foregroundStyle(Theme.Palette.amber)
                    }
                    if let a = acquisition { Tag(text: "ACQUISITION: \(a.state.label)", tint: a.state == .readyForImport ? Theme.Palette.mint : Theme.Palette.amber) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func field(_ label: String, _ value: String, tint: Color = Color.jarvisPrimary, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(label.uppercased()).font(Theme.Typography.label).foregroundStyle(Color.jarvisTertiary).frame(width: 118, alignment: .leading)
            Text(value).font(mono ? Theme.Typography.mono : Theme.Typography.body).foregroundStyle(tint).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Acquisitions (quarantine)

private struct AcquisitionsGroup: View {
    @Environment(AppContext.self) private var app
    let model: ResearchViewModel
    var body: some View {
        if !model.acquisitions.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("QUARANTINE · DOWNLOADED ≠ TRUSTED").jarvisLabel(Theme.Opacity.textTertiary).accessibilityAddTraits(.isHeader)
                ForEach(model.acquisitions) { a in
                    HUDCard(a.name, trailing: { Tag(text: a.state.label, tint: a.state == .readyForImport ? Theme.Palette.mint : a.state == .rejected || a.state == .failed ? Theme.Palette.coral : Theme.Palette.amber) }) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("\(a.trust.rawValue) · \(a.detectedType ?? "?") · \(a.size.map { "\($0 / 1024) KB" } ?? "—") · from \(a.finalHost ?? "—")").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                            if let h = a.sha256 { Text("SHA-256 \(h)").font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                            Text("Licence \(a.licenseID ?? "UNKNOWN") · price when acquired \(a.priceState?.rawValue ?? "UNKNOWN") · checksum from the publisher: \(a.hashMatchesPublished == .yes ? "matches" : a.hashMatchesPublished == .no ? "MISMATCH" : "none given")").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                            if let i = a.inspection { ForEach(i.findings.prefix(4), id: \.self) { Text("• \($0)").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) } }
                            if let f = a.failure { Text(f).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.coral) }
                            if let to = a.importedTo { Text("Imported into the project at \(to)").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.mint) }
                            HStack(spacing: Theme.Spacing.s) {
                                Button("OPEN SOURCE PAGE") { model.open(a.sourceURL) }.buttonStyle(.hudSecondary).fixedSize()
                                if a.quarantinePath != nil { Button("SHOW IN FINDER") { model.reveal(a, in: app.paths) }.buttonStyle(.hudSecondary).fixedSize() }
                                if a.state == .readyForImport, a.importedTo == nil {
                                    Button("IMPORT INTO PROJECT…") { model.requestImport(a) }.buttonStyle(.hudSecondary).fixedSize()
                                        .accessibilityHint("Starts an import task that asks for your approval first. Use a disposable copy of the project.")
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }
}
