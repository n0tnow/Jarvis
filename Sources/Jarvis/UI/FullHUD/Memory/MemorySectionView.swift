import SwiftUI

// MARK: - Project Memory screen (V0.10): what JARVIS believes about the project, why, and how current it is

struct MemorySectionView: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let model = app.memoryModel
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                header(model)
                if let m = model.message { MemoryMessageBar(text: m) { model.message = nil } }
                if !model.isEnabled { disabledCard } else if model.project == nil { noProjectCard } else {
                    SearchBar(model: model)
                    if model.rows.isEmpty { emptyCard(model) } else { MemoryList(model: model) }
                    if let d = model.detail { MemoryDetail(item: d, model: model) }
                    DiagnosticsCard(model: model)
                }
            }
            .frame(maxWidth: 860)
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("memory.section")
        .onAppear { model.refresh() }
        .onChange(of: app.memory.revision) { _, _ in model.revisionChanged() }
        .onChange(of: app.preferences.projectRoot) { _, _ in model.refresh() }
    }

    private func header(_ model: MemoryViewModel) -> some View {
        HUDCard("Project Memory") {
            Tag(text: "DERIVED · NOT HISTORY", tint: Theme.Palette.violet)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let p = model.project { Text(p.name).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary) }
                Text("What JARVIS has learned about this project — decisions, constraints, failures, lessons, research and asset decisions — each with the evidence it came from. Ask in plain words (“what did we decide about the camera?”, “Playwright hakkında ne karar vermiştik?”), or say “remember that …”.")
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                Text("Memory is context, never authority: the project's current files always win, and no memory can approve anything or relax a safety rule. Forgetting or correcting memory never rewrites Git, task history or the audit trail.")
                    .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }

    private var disabledCard: some View {
        HUDCard("Project Memory is off") {
            Text("Nothing is read, written or added to agents' context. Everything else works as before. Turn it on in Settings → Project Memory.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
        }
    }
    private var noProjectCard: some View {
        HUDCard("No project chosen") {
            Text("Project memory belongs to one project. Open Tasks and choose a project folder (Choose folder…).").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
        }
    }
    private func emptyCard(_ model: MemoryViewModel) -> some View {
        HUDCard("Nothing here yet") {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(model.query.isEmpty ? "No memories match this view. JARVIS learns from finished tasks and verified research, and can read this project's own decision records, known issues and rules." : "Nothing in this project's memory matches “\(model.query)”.")
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                if model.query.isEmpty { Button("BUILD MEMORY FROM PROJECT DOCS") { model.bootstrap() }.buttonStyle(.hudPrimary).fixedSize().accessibilityHint("Reads DECISIONS.md, KNOWN_ISSUES.md, AGENTS.md and the development log if the project has them") }
            }
        }
    }
}

private struct MemoryMessageBar: View {
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

// MARK: Search and filters

private struct SearchBar: View {
    @Bindable var model: MemoryViewModel
    @State private var note = ""
    var body: some View {
        HUDCard("Search") {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.s) {
                    TextField("Search the project's memory (English or Turkish)", text: $model.query)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Search project memory").accessibilityIdentifier("memory.search")
                        .onSubmit { model.refresh() }
                    Button("SEARCH") { model.refresh() }.buttonStyle(.hudSecondary).fixedSize()
                }
                HStack(spacing: Theme.Spacing.s) {
                    Picker("Show", selection: $model.statusFilter) { ForEach(MemoryViewModel.StatusFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 300).accessibilityLabel("Status filter").onChange(of: model.statusFilter) { _, _ in model.refresh() }
                    Picker("Type", selection: $model.typeFilter) {
                        Text("All types").tag(MemoryType?.none)
                        ForEach(MemoryType.allCases, id: \.self) { Text($0.label).tag(MemoryType?.some($0)) }
                    }.frame(maxWidth: 190).accessibilityLabel("Type filter").onChange(of: model.typeFilter) { _, _ in model.refresh() }
                    Picker("Importance", selection: $model.importanceFilter) {
                        Text("Any importance").tag(MemoryImportance?.none)
                        ForEach(MemoryImportance.allCases.reversed(), id: \.self) { Text($0.label.capitalized).tag(MemoryImportance?.some($0)) }
                    }.frame(maxWidth: 190).accessibilityLabel("Importance filter").onChange(of: model.importanceFilter) { _, _ in model.refresh() }
                }
                if let n = model.semanticNote { Text("Search mode: keyword + structured — \(n).").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
                HStack(spacing: Theme.Spacing.s) {
                    TextField("Add a note: “remember that …” (project-wide, never a task detail)", text: $note).textFieldStyle(.roundedBorder).accessibilityLabel("Remember a project note")
                    Button("REMEMBER") { model.remember(note); note = "" }.buttonStyle(.hudSecondary).fixedSize().disabled(note.trimmingCharacters(in: .whitespaces).count < 8)
                    Button("BUILD FROM PROJECT DOCS") { model.bootstrap() }.buttonStyle(.hudSecondary).fixedSize().accessibilityHint("Idempotent: running it again adds nothing twice")
                }
            }
        }
    }
}

// MARK: List

private func statusTint(_ s: MemoryStatus) -> Color {
    switch s { case .current: Theme.Palette.mint; case .stale, .disputed: Theme.Palette.amber; case .unverified: Theme.Palette.violet; case .superseded, .archived: Color.white.opacity(0.45); case .forgotten: Theme.Palette.coral }
}

private struct MemoryList: View {
    let model: MemoryViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("\(model.rows.count) MEMORIES").jarvisLabel(Theme.Opacity.textTertiary).accessibilityAddTraits(.isHeader)
            ForEach(model.rows.prefix(80)) { row in
                let selected = model.selectedID == row.id
                Button { model.selectedID = row.id } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Theme.Spacing.s) {
                            Tag(text: row.item.type.label.uppercased(), tint: Theme.Palette.accent)
                            Tag(text: row.item.status.label, tint: statusTint(row.item.status))
                            Tag(text: row.item.strength.label)
                            if row.item.importance >= .high { Tag(text: row.item.importance.label, tint: Theme.Palette.coral) }
                            if row.item.pinned { Image(systemName: "pin.fill").foregroundStyle(Theme.Palette.amber).accessibilityLabel("Pinned") }
                            Spacer(minLength: 0)
                        }
                        Text(row.item.summary).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).lineLimit(3).multilineTextAlignment(.leading)
                        if let c = row.caveat { Text(c).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
                        if !row.reasons.isEmpty { Text("why it matched: " + row.reasons.joined(separator: " · ")).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
                    }
                    .padding(Theme.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HUDCardBackground(accent: selected ? Theme.Palette.accent : Color.white.opacity(0.3), raised: selected))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint("Shows where this memory came from")
            }
        }
    }
}

// MARK: Detail

private struct MemoryDetail: View {
    let item: MemoryItem
    let model: MemoryViewModel
    @State private var correction = ""
    @State private var confirmForget = false

    var body: some View {
        HUDCard("Where did JARVIS get this?") {
            Tag(text: item.status.label, tint: statusTint(item.status))
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(item.summary).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary).textSelection(.enabled)
                if let d = item.details { Text(d).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary).textSelection(.enabled) }
                if let c = MemoryRetriever.caveat(item, now: Date()) { Text(c).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.l, verticalSpacing: 3) {
                    row("Type", item.type.label); row("Evidence", item.strength.label); row("Importance", item.importance.label.capitalized)
                    row("Origin", item.origin.rawValue); row("Scope", item.scope == .project ? "project" : "task-local"); if let a = item.area { row("Area", a) }
                    row("Recorded", item.createdAt.formatted(date: .abbreviated, time: .shortened)); if let v = item.lastVerifiedAt { row("Last verified", v.formatted(date: .abbreviated, time: .shortened)) }
                    if !item.tags.isEmpty { row("Tags", item.tags.joined(separator: ", ")) }
                    if item.userCorrected { row("Correction", "stated by you") }
                }
                .font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)

                Text("SOURCES").jarvisLabel(Theme.Opacity.textTertiary).accessibilityAddTraits(.isHeader)
                ForEach(Array(item.sources.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .top, spacing: Theme.Spacing.s) {
                        Tag(text: s.kind.rawValue.uppercased())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.label).font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary)
                            if let l = s.locator { Text(l).font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary) }
                        }
                    }
                }
                if item.sources.isEmpty { Text("No source recorded (older record).").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }

                if !model.related.isEmpty {
                    Text("RELATED").jarvisLabel(Theme.Opacity.textTertiary).accessibilityAddTraits(.isHeader)
                    ForEach(model.related) { r in
                        Button { model.selectedID = r.id } label: {
                            HStack(spacing: Theme.Spacing.s) { Tag(text: r.status.label, tint: statusTint(r.status)); Text(MemoryText.clip(r.summary, 120)).font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary).lineLimit(2) }
                        }.buttonStyle(.plain).accessibilityHint("Opens the related memory")
                    }
                }

                Rectangle().fill(Color.white.opacity(Theme.Opacity.hairline)).frame(height: 0.8)
                if item.status == .forgotten {
                    Button("RESTORE") { model.restore(item.id) }.buttonStyle(.hudSecondary).fixedSize()
                } else {
                    HStack(spacing: Theme.Spacing.s) {
                        Button(item.pinned ? "UNPIN" : "PIN") { model.pin(item.id, !item.pinned) }.buttonStyle(.hudSecondary).fixedSize().accessibilityHint("A pinned memory is preferred when relevant, but never overrides the project's current state")
                        Menu("Importance: \(item.importance.label.capitalized)") { ForEach(MemoryImportance.allCases.reversed(), id: \.self) { i in Button(i.label.capitalized) { model.setImportance(item.id, i) } } }.fixedSize()
                        Button("FORGET…") { confirmForget = true }.buttonStyle(.hudSecondary).fixedSize()
                    }
                    if item.status.isLive {
                        HStack(spacing: Theme.Spacing.s) {
                            TextField("Correct it: state what is true now (this replaces the memory; the old one stays in History)", text: $correction).textFieldStyle(.roundedBorder).accessibilityLabel("Correction text")
                            Button("CORRECT") { model.correct(item.id, with: correction); correction = "" }.buttonStyle(.hudSecondary).fixedSize().disabled(correction.trimmingCharacters(in: .whitespaces).count < 8)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Forget this memory?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { model.forget(item.id) }
        } message: {
            Text("This prevents the memory from being used in future JARVIS context. It does not rewrite Git, task history, the audit trail or research evidence, and you can restore it from the Forgotten view.")
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View { GridRow { Text(k.uppercased()).foregroundStyle(Color.jarvisTertiary); Text(v) } }
}

// MARK: Diagnostics

private struct DiagnosticsCard: View {
    let model: MemoryViewModel
    var body: some View {
        HUDCard("Diagnostics") {
            Button(model.showDiagnostics ? "HIDE" : "SHOW") { model.showDiagnostics.toggle() }.buttonStyle(.hudSecondary).fixedSize()
        } content: {
            if model.showDiagnostics, let d = model.diagnostics {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Group {
                        Text("\(d.total) memories · " + MemoryStatus.allCases.compactMap { s in d.byStatus[s].map { "\($0) \(s.rawValue)" } }.joined(separator: " · "))
                        Text(MemoryType.allCases.compactMap { t in d.byType[t].map { "\(t.label) \($0)" } }.joined(separator: " · "))
                        Text("Semantic index: \(d.indexState) — \(d.indexed) indexed, \(d.unindexed) not yet, \(d.invalid) invalid")
                        Text("Embedding model: \(d.embeddingModel) @ \(d.embeddingRevision) · helper \(d.helperState)" + (d.helperResidentMB.map { " · \($0) MB" } ?? ""))
                        if let r = d.lastRebuild { Text("Last rebuild: \(r.formatted(date: .abbreviated, time: .shortened))") }
                        if let i = d.lastIngest { Text("Last ingestion: \(i)") }
                        if let l = d.lastRetrievalMs { Text(String(format: "Last retrieval: %.0f ms", l)) }
                        if let c = d.lastContext { Text("Last agent context: \(c)") }
                        Text("Schema v\(d.schemaVersion)")
                    }.font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary)
                    if !model.contextUses.isEmpty {
                        Text("RECENT AGENT CONTEXT").jarvisLabel(Theme.Opacity.textTertiary).accessibilityAddTraits(.isHeader)
                        ForEach(model.contextUses.prefix(5)) { u in Text("\(u.agentType) · \(u.items) memories · \(u.chars) chars · run \(u.runID.map { String($0.uuidString.prefix(8)) } ?? "—")").font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary) }
                    }
                    HStack(spacing: Theme.Spacing.s) {
                        Button(model.rebuilding ? "REBUILDING…" : "REBUILD SEMANTIC INDEX") { model.rebuildIndex() }.buttonStyle(.hudSecondary).fixedSize().disabled(model.rebuilding)
                        if model.rebuilding { Button("CANCEL") { model.cancelRebuild() }.buttonStyle(.hudSecondary).fixedSize() }
                    }
                }
            } else {
                Text("Counts, embedding model, index health and what agents were given.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }
}
