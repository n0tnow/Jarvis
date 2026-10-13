import SwiftUI

/// The Agents (Observatory) area of the Full HUD: provider overview, active/recent runs, history, timeline, and a per-run
/// detail with a live sanitized console. Everything is a view of REAL state (`AgentObservatory`).
struct AgentsSectionView: View {
    @Environment(AppContext.self) private var app
    @Environment(\.hudIsNarrow) private var narrow

    enum Mode: String, CaseIterable, Identifiable { case live = "LIVE", history = "HISTORY", timeline = "TIMELINE"; var id: String { rawValue } }
    @State private var mode: Mode = .live
    @State private var filter = JarvisRepository.RunFilter()
    @State private var pageSize = 25

    private var observatory: AgentObservatory { app.observatory }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 1080
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                toolbar
                if wide {
                    HStack(alignment: .top, spacing: Theme.Spacing.m) {
                        ScrollView { listColumn.padding(.trailing, 2) }
                            .frame(width: min(470, geo.size.width * 0.42))
                        detailColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let id = observatory.selectedRunID {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Button { observatory.selectedRunID = nil } label: { Label("ALL AGENTS", systemImage: "chevron.left").font(Theme.Typography.label) }
                            .buttonStyle(.hudSecondary).accessibilityLabel("Back to all agents")
                        RunDetailView(runID: id)
                    }
                } else {
                    ScrollView { listColumn }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.m) {
            Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 270)
                .accessibilityLabel("Agents view")
            if mode == .history { historyFilters }
            Spacer()
            let active = app.hub.activeRuns.count
            Text(active == 0 ? "NO ACTIVE AGENTS" : "\(active) ACTIVE").font(Theme.Typography.label).tracking(0.8)
                .foregroundStyle(active == 0 ? Color.jarvisTertiary : Theme.Palette.accent)
            if app.preferences.showDeveloperControls { simulateMenu }
        }
    }

    private var simulateMenu: some View {
        Menu {
            Button("Simulate agents (developer)") { app.observatory.demo?.startShowcase() }
            Button("Console stress stream (developer)") { app.observatory.demo?.startStress() }
            Button("Stop simulation") { app.observatory.demo?.stopAll() }
        } label: { Text("SIMULATE").font(Theme.Typography.label) }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Developer simulation")
    }

    private var historyFilters: some View {
        HStack(spacing: Theme.Spacing.s) {
            Picker("Provider", selection: Binding(get: { filter.engine?.rawValue ?? "all" }, set: { filter.engine = ProviderID(rawValue: $0); pageSize = 25 })) {
                Text("All providers").tag("all")
                ForEach(ProviderID.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            }.labelsHidden().frame(width: 140)
            Picker("Status", selection: Binding(get: { filter.statuses.first?.rawValue ?? "all" }, set: { filter.statuses = AgentRunStatus(rawValue: $0).map { [$0] } ?? []; pageSize = 25 })) {
                Text("Any status").tag("all")
                ForEach([AgentRunStatus.succeeded, .failed, .cancelled, .escalated, .interrupted], id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }.labelsHidden().frame(width: 120)
            TextField("Search task, agent, model", text: Binding(get: { filter.text ?? "" }, set: { filter.text = $0.isEmpty ? nil : $0; pageSize = 25 }))
                .textFieldStyle(.roundedBorder).frame(width: 190)
        }
    }

    // MARK: Left column

    @ViewBuilder private var listColumn: some View {
        switch mode {
        case .live: liveColumn
        case .history: historyColumn
        case .timeline: timelineColumn
        }
    }

    private var liveColumn: some View {
        let cards = observatory.providerCards()
        let active = app.hub.activeRuns
        let recent = Array(app.hub.recentFinished.prefix(6))
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("PROVIDERS").jarvisLabel(Theme.Opacity.textTertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: Theme.Spacing.s)], spacing: Theme.Spacing.s) {
                ForEach(cards) { card in
                    ProviderCardView(card: card, isSelected: observatory.selectedRunID.map { id in card.activeRuns.contains { $0.id == id } || card.lastRun?.id == id } ?? false) {
                        observatory.selectedRunID = card.activeRuns.first?.id ?? card.lastRun?.id
                    }
                }
            }
            Text("ACTIVE RUNS").jarvisLabel(Theme.Opacity.textTertiary)
            if active.isEmpty {
                Text("Nothing is running. Providers that are READY are installed and signed in — that does not mean an agent is working.")
                    .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
            ForEach(active) { run in runRow(run) }
            if !recent.isEmpty {
                Text("RECENT (THIS SESSION)").jarvisLabel(Theme.Opacity.textTertiary)
                ForEach(recent) { run in runRow(run) }
            }
        }
    }

    private func runRow(_ run: AgentRunView) -> some View {
        RunRowView(run: run, taskTitle: run.taskID.flatMap { app.taskEngine.view($0)?.task.title }, isSelected: observatory.selectedRunID == run.id, onSelect: { observatory.selectedRunID = run.id },
                   onStop: { _ = app.hub.requestStop(run.id) })
    }

    private var historyColumn: some View {
        let rows = observatory.history(filter: filter, limit: pageSize, offset: 0)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("HISTORY").jarvisLabel(Theme.Opacity.textTertiary)
            if rows.isEmpty { Text("No matching runs yet.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
            ForEach(rows) { run in runRow(run) }
            if rows.count >= pageSize {
                Button("Load more") { pageSize += 25 }.buttonStyle(.hudSecondary).accessibilityLabel("Load more history")
            }
        }
        .id(observatory.historyRevision)
    }

    private var timelineColumn: some View {
        let _ = app.hub.revision                                         // refresh at the coalesced rate while runs are live
        let items = observatory.timeline(limit: 80)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("ACTIVITY TIMELINE").jarvisLabel(Theme.Opacity.textTertiary)
            if items.isEmpty { Text("No recorded execution events yet.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
            ForEach(items) { item in
                Button { observatory.selectedRunID = item.runID } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Text(item.time, format: .dateTime.hour().minute().second()).font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary).monospacedDigit()
                        Text(item.severity.marker).font(Theme.Typography.mono).foregroundStyle(item.severity.tint).frame(width: 10)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.text).font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary).lineLimit(2)
                            Text("\(item.agent) · \(item.provider)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.text). \(item.agent), \(item.provider)")
            }
        }
    }

    // MARK: Right column

    @ViewBuilder private var detailColumn: some View {
        if let id = observatory.selectedRunID { RunDetailView(runID: id) }
        else {
            HUDCard("Agent detail", trailing: { EmptyView() }) {
                Text("Select a provider or a run to see its live console, steps, files and timeline.")
                    .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }
}

// MARK: - Detail

struct RunDetailView: View {
    let runID: UUID
    @Environment(AppContext.self) private var app
    @State private var tab: Tab = .console
    @State private var extras: RunDetailData?
    @State private var viewer: (title: String, text: String)?
    private let copyProxy = ConsoleCopyProxy()

    enum Tab: String, CaseIterable, Identifiable { case overview = "OVERVIEW", console = "CONSOLE", timeline = "TIMELINE", files = "FILES", artifacts = "ARTIFACTS"; var id: String { rawValue } }

    private var run: AgentRunView? { app.observatory.runView(runID) }

    private var availableTabs: [Tab] {
        var t: [Tab] = [.overview, .console, .timeline]
        if !(extras?.files.isEmpty ?? true) { t.append(.files) }
        if !(extras?.artifacts.isEmpty ?? true) { t.append(.artifacts) }
        return t
    }

    var body: some View {
        if let run {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                header(run)
                Picker("", selection: $tab) { ForEach(availableTabs) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Detail section")
                Group {
                    switch tab {
                    case .overview: ScrollView { overview(run) }
                    case .console: consoleTab(run)
                    case .timeline: ScrollView { timeline(run) }
                    case .files: ScrollView { files }
                    case .artifacts: ScrollView { artifacts }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(Theme.Spacing.m)
            .background(HUDCardBackground(cornerRadius: Theme.Radius.m))
            .task(id: "\(runID)-\(run.phase.rawValue)") { extras = app.observatory.detail(runID) }
            .onChange(of: runID) { _, _ in tab = .console; extras = nil; viewer = nil }
            .sheet(isPresented: Binding(get: { viewer != nil }, set: { if !$0 { viewer = nil } })) { viewerSheet }
        } else {
            Text("This run is no longer available.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
        }
    }

    private func header(_ run: AgentRunView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Spacing.s) {
                Text(AgentRole.displayName(forAgentType: run.agentType)).font(Theme.Typography.title).foregroundStyle(Color.jarvisPrimary)
                PhaseChip(phase: run.phase, simulated: run.isSimulated)
                Spacer()
                ElapsedLabel(run: run).font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary)
                if run.phase.isActive {
                    Button { _ = app.hub.requestStop(runID) } label: { Label("STOP", systemImage: "stop.fill").font(Theme.Typography.label) }
                        .buttonStyle(.hudDestructive).accessibilityLabel("Stop \(run.agentType)").accessibilityIdentifier("agents.detail.stop")
                }
            }
            Text("\(AgentObservatory.providerLabel(run)) — \(run.label)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(2)
            ProgressLine(run: run)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.spoken)
    }

    // Console

    private func consoleTab(_ run: AgentRunView) -> some View {
        let _ = app.hub.revision                                          // coalesced (≤ ~8 Hz) — never per token
        let live = app.hub.consoleSnapshot(runID)
        let events = live.events.isEmpty ? app.observatory.consoleEvents(runID) : live.events
        let rendered = ConsoleRenderer.render(events: events, tail: live.tail, dropped: live.droppedEvents)
        let key = "\(runID)-\(events.last?.id ?? 0)-\(events.count)-\(live.tail.count)-\(live.droppedEvents)"
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            AgentConsoleTextView(content: rendered, key: key, proxy: copyProxy)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.s).fill(Color.black.opacity(0.25)))
            HStack {
                Text("Sanitized output · read-only · select text and press ⌘C").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                Spacer()
                Button("Copy all") { copyProxy.copyAll() }.buttonStyle(.hudSecondary).accessibilityLabel("Copy all visible console text")
            }
        }
    }

    // Overview

    @ViewBuilder private func overview(_ run: AgentRunView) -> some View {
        let d = extras ?? app.observatory.detail(runID)
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            KeyValueRow(key: "Status", value: run.phase.label, valueTint: run.phase.tint)
            KeyValueRow(key: "Provider", value: run.engine.displayName)
            if let m = run.model { KeyValueRow(key: "Model", value: m) }
            KeyValueRow(key: "Agent (role)", value: AgentRole.displayName(forAgentType: run.agentType))
            KeyValueRow(key: "Task", value: run.label)
            KeyValueRow(key: "Activity", value: run.activity)
            KeyValueRow(key: "Started", value: run.startedAt.formatted(date: .abbreviated, time: .standard))
            KeyValueRow(key: "Progress", value: run.progress.label.map { "\($0) · \(run.progress.source.rawValue)" } ?? "Indeterminate — no measurable steps")
            if run.retryCount > 0 { KeyValueRow(key: "Repair attempts", value: "\(run.retryCount)") }
            if let to = run.escalatedTo { KeyValueRow(key: "Escalated to", value: to, valueTint: Theme.Palette.amber) }
            if let from = run.escalatedFrom { KeyValueRow(key: "Escalated from", value: from, valueTint: Theme.Palette.amber) }
            if run.inputTokens != nil || run.outputTokens != nil {
                KeyValueRow(key: "Tokens (provider-reported)", value: "in \(run.inputTokens.map(String.init) ?? "–") / out \(run.outputTokens.map(String.init) ?? "–")")
            }
            if let d {
                if d.validation != .notRun { KeyValueRow(key: "Validation", value: d.validation.rawValue.uppercased()) }
                if let r = d.resultSummary { KeyValueRow(key: "Result", value: r) }
                if let s = d.selectionSummary { KeyValueRow(key: "Why this provider", value: s) }
                if !d.toolsUsed.isEmpty { KeyValueRow(key: "Tools", value: d.toolsUsed.joined(separator: ", ")) }
                if let parent = run.parent { relation("Parent run", parent) }
                ForEach(d.children, id: \.self) { relation("Child run", $0) }
                if !run.steps.isEmpty || !d.steps.isEmpty {
                    Text("STEPS").jarvisLabel(Theme.Opacity.textTertiary).padding(.top, Theme.Spacing.s)
                    ForEach(run.steps.isEmpty ? d.steps : run.steps) { step in
                        HStack(spacing: Theme.Spacing.s) {
                            Image(systemName: Self.symbol(step.state)).foregroundStyle(Self.tint(step.state)).font(.system(size: 11)).frame(width: 14)
                            Text(step.title).font(Theme.Typography.caption).foregroundStyle(step.state == .pending ? Color.jarvisTertiary : Color.jarvisPrimary).lineLimit(1)
                            Spacer()
                            Text(step.state.rawValue).font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary)
                        }.accessibilityElement(children: .combine).accessibilityLabel("\(step.title), \(step.state.rawValue)")
                    }
                }
            }
        }
    }

    private func relation(_ key: String, _ id: UUID) -> some View {
        Button { app.observatory.selectedRunID = id } label: {
            HStack { Text(key).jarvisLabel(Theme.Opacity.textTertiary); Spacer(); Text(app.observatory.runView(id).map { "\($0.agentType) · \($0.phase.label)" } ?? "open").font(Theme.Typography.mono).foregroundStyle(Theme.Palette.accent) }
        }.buttonStyle(.plain)
    }

    private static func symbol(_ s: StepState) -> String { switch s { case .done: "checkmark.circle.fill"; case .active: "arrow.right.circle.fill"; case .failed: "xmark.circle.fill"; case .skipped: "minus.circle"; case .pending: "circle" } }
    private static func tint(_ s: StepState) -> Color { switch s { case .done: Theme.Palette.mint; case .active: Theme.Palette.accent; case .failed: Theme.Palette.coral; default: Color.jarvisTertiary } }

    // Timeline

    private func timeline(_ run: AgentRunView) -> some View {
        let _ = app.hub.revision
        let live = app.hub.consoleSnapshot(runID, maxEvents: 600).events
        let events = (live.isEmpty ? app.observatory.consoleEvents(runID) : live).filter { $0.kind != .providerOutput }
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if events.isEmpty { Text("No lifecycle events recorded.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
            ForEach(events) { e in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text(e.timestamp, format: .dateTime.hour().minute().second()).font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary).monospacedDigit()
                    Text(e.severity.marker).font(Theme.Typography.mono).foregroundStyle(e.severity.tint).frame(width: 10)
                    Text(e.summary).font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary)
                    Spacer(minLength: 0)
                }.accessibilityElement(children: .combine)
            }
        }
    }

    // Files / artifacts (shown only when they exist)

    private var files: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("\(extras?.files.count ?? 0) files changed").jarvisLabel(Theme.Opacity.textTertiary)
            ForEach(extras?.files ?? [], id: \.id) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((f.path as NSString).lastPathComponent).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                        Text("\(f.changeType)\(f.verificationResult.map { " · \($0)" } ?? "")").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                    }
                    Spacer()
                    if let aid = f.diffArtifactID, let a = extras?.artifacts.first(where: { $0.id == aid }) {
                        Button("View diff") { viewer = ((f.path as NSString).lastPathComponent, app.observatory.artifactText(a) ?? "Diff unavailable.") }
                            .buttonStyle(.hudSecondary).accessibilityLabel("View diff of \((f.path as NSString).lastPathComponent)")
                    }
                }
            }
        }
    }

    private var artifacts: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(extras?.artifacts ?? [], id: \.id) { a in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.type).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)) · \(a.createdAt.formatted(date: .omitted, time: .standard))").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                    }
                    Spacer()
                    Button("Open") { viewer = (a.type, app.observatory.artifactText(a) ?? "Artifact unavailable or modified.") }.buttonStyle(.hudSecondary)
                }
            }
        }
    }

    private var viewerSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack { Text(viewer?.title ?? "").font(Theme.Typography.headline); Spacer(); Button("Close") { viewer = nil }.keyboardShortcut(.cancelAction) }
            ScrollView { Text(viewer?.text ?? "").font(Theme.Typography.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(Theme.Spacing.l).frame(width: 640, height: 420)
    }
}
