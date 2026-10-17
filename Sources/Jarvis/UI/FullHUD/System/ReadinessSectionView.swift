import SwiftUI

// MARK: - System & Readiness (V0.15): “what is ready?” — read on appear and on Recheck, never polled. Buttons map to the closed `SetupAction` list.

private func stateTint(_ s: ReadinessState) -> Color {
    switch s {
    case .ready: Theme.Palette.mint
    case .available, .notRunning: Color.jarvisSecondary
    case .off: Theme.Palette.amber
    case .optionalAbsent, .unknown: Color.jarvisTertiary
    case .notInstalled, .signInRequired, .permissionNeeded, .degraded, .stale, .unavailable: Theme.Palette.amber
    }
}

/// The System page: a summary first (what is ready, what needs attention, what is optional), then every area as its own card on the page grid.
struct ReadinessPanel: View {
    @Environment(AppContext.self) private var app
    @Binding var message: String?
    @Binding var busy: Bool
    @State private var confirming: SetupAction?

    var body: some View {
        let snap = app.readiness.snapshot
        let attention = snap.attention
        let optional = snap.items.filter { $0.state == .optionalAbsent || $0.state == .notInstalled }
        let ready = snap.items.filter { $0.state == .ready || $0.state == .available }
        let tiles = snap.tiles                          // the same numbers the spoken / typed system status reports
        VStack(alignment: .leading, spacing: Theme.Grid.gutter) {
            if !app.preferences.firstRunCompleted, AppInfo.isApplicationBundle, !app.intelligenceIsStubbed { FirstRunCard() }

            // Summary
            HStack(alignment: .top, spacing: Theme.Grid.gutter) {
                summaryTile("Ready", tiles.ready, .ready, "Verified by a safe check, or present and loaded on demand.")
                summaryTile("Needs attention", tiles.attention, attention.isEmpty ? .ready : .attention, attention.isEmpty ? "Nothing needs you right now." : attention.prefix(3).map(\.name).joined(separator: " · "))
                summaryTile("Optional", tiles.optional, .optional, "Not set up; nothing needs it right now.")
            }
            if let m = message { Text(m).font(Theme.Typography.meta).foregroundStyle(Theme.Palette.accent).accessibilityLabel("Result: \(m)") }
            if app.setupRunner.state != .idle { SetupProgressView() }

            if !attention.isEmpty {
                Card("Needs attention", prominence: .standard, trailing: { StatusBadge(kind: .attention, text: "\(attention.count)") }) {
                    VStack(spacing: Theme.Spacing.m) { ForEach(attention) { row($0) } }
                }
            }

            ResponsiveColumns(minColumn: 470) {
                ForEach(ReadinessCategory.allCases) { cat in
                    let items = snap.items(in: cat)
                    if !items.isEmpty {
                        Card(cat.rawValue, trailing: { StatusBadge(kind: Self.worst(items)) }) {
                            VStack(spacing: Theme.Spacing.m) { ForEach(items) { row($0) } }
                        }
                    }
                }
            }
        }
        .onAppear { app.readiness.refresh(); Task { await app.voice.refreshProviders(); await app.notifier.refreshStatus(); app.readiness.refresh() } }
        .alert(item: Binding(get: { confirming.map { ConfirmItem(action: $0) } }, set: { confirming = $0?.action })) { c in
            let plan = SetupCatalog.plan(for: c.action)
            return Alert(title: Text(plan?.title ?? c.action.title),
                         message: Text(plan.map { "Source: \($0.source).\nDownload ≈ \(SetupRefusal.gb($0.downloadBytes)), installed ≈ \(SetupRefusal.gb($0.installedBytes)).\nWhere: \($0.destination).\nNothing else is installed or changed." } ?? ""),
                         primaryButton: .default(Text("Set Up")) { Task { message = await ReadinessActions.run(c.action, in: app); app.readiness.refresh() } },
                         secondaryButton: .cancel())
        }
    }

    private static func worst(_ items: [ReadinessItem]) -> StatusKind {
        if items.contains(where: { $0.state.needsAttention }) { return .attention }
        if items.allSatisfy({ $0.state == .ready }) { return .ready }
        if items.contains(where: { $0.state == .ready || $0.state == .available }) { return .available }
        return .optional
    }

    private func summaryTile(_ title: String, _ n: Int, _ kind: StatusKind, _ note: String) -> some View {
        Card(prominence: .standard) {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(title.uppercased()).font(Theme.Typography.sectionTitle).tracking(0.9).foregroundStyle(Color.jarvisSecondary); Spacer(); Image(systemName: kind.symbol).foregroundStyle(kind.tint).accessibilityHidden(true) }
                Text("\(n)").font(.system(size: 34, weight: .light)).foregroundStyle(Color.jarvisPrimary).monospacedDigit()
                Text(note).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(n). \(note)")
    }

    private struct ConfirmItem: Identifiable { let action: SetupAction; var id: String { action.rawValue } }

    private func row(_ item: ReadinessItem) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(Theme.Typography.rowTitle).foregroundStyle(Color.jarvisPrimary)
                if !item.detail.isEmpty { Text(item.detail).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                if let note = item.state.detailNote { Text(note).font(Theme.Typography.meta).foregroundStyle(Theme.Palette.amber).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Theme.Spacing.s)
            VStack(alignment: .trailing, spacing: Theme.Spacing.s) {
                StatusBadge(kind: item.state.statusKind)
                if let a = item.action {
                    Button(a.title) { act(a) }.buttonStyle(.hudSecondary).fixedSize().disabled(a.isInstall && app.setupRunner.isRunning)
                        .accessibilityIdentifier("readiness.\(item.id).\(a.rawValue)")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name): \(item.state.label.lowercased()). \(item.detail)")
    }

    private func act(_ a: SetupAction) {
        if a.isInstall { confirming = a; return }
        Task { message = await ReadinessActions.run(a, in: app) ?? message }
    }
}

private struct SetupProgressView: View {
    @Environment(AppContext.self) private var app
    var body: some View {
        let r = app.setupRunner!
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            switch r.state {
            case .running(let a): HStack { ProgressView().controlSize(.small); Text("Setting up: \(SetupCatalog.plan(for: a)?.title ?? a.title)…").font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                Spacer(); Button("CANCEL") { Task { await r.cancel() } }.buttonStyle(.hudSecondary).fixedSize().accessibilityIdentifier("readiness.cancelSetup") }
            case .finished(_, let ok, let summary): Text(summary).font(Theme.Typography.body).foregroundStyle(ok ? Theme.Palette.mint : Theme.Palette.amber)
            case .cancelled(let a): Text("Cancelled: \(SetupCatalog.plan(for: a)?.title ?? a.title). Running it again continues safely.").font(Theme.Typography.body).foregroundStyle(Theme.Palette.amber)
            case .idle: EmptyView()
            }
            if let refusal = r.lastRefusal { Text(refusal.description).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
            if !r.log.isEmpty {
                Text(r.log.suffix(4).joined(separator: "\n")).font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary).lineLimit(5).textSelection(.enabled)
            }
        }
        .padding(Theme.Spacing.s).background(RoundedRectangle(cornerRadius: Theme.Radius.s).fill(Color.white.opacity(0.04)))
    }
}

// MARK: First run

/// A lightweight readiness walk-through, not a carousel: six stages, each showing real state and real buttons; every optional stage can be skipped; nothing blocks using JARVIS.
struct FirstRunCard: View {
    @Environment(AppContext.self) private var app
    @State private var stage = 0
    private static let stages: [(title: String, blurb: String, categories: [ReadinessCategory])] = [
        ("Welcome", "JARVIS lives in the menu bar. This takes a minute and nothing here is required — you can skip any step and come back from System.", [.core]),
        ("Permissions", "macOS asks only when a feature needs a permission, and only you can allow it. Nothing is requested until you press a button.", [.permissions, .computer]),
        ("Intelligence", "JARVIS uses the Claude Code, Codex and OpenCode you already have. It cannot sign in for you and never uses a paid API key.", [.intelligence]),
        ("Local models", "Optional on-device models for lightweight work, speech recognition and visual grounding. Existing installations are reused.", [.localAI]),
        ("Voice", "Hold the right ⌥ key to talk. Wake word and a natural voice are optional; the Apple system voice works without any download.", [.voice]),
        ("Ready", "That is everything JARVIS can check about itself. Unity and MCP servers are started only when a task needs them.", [.unity, .mcp, .startup]),
    ]

    var body: some View {
        let s = Self.stages[stage]
        HUDCard("Welcome to JARVIS · step \(stage + 1) of \(Self.stages.count)") {
            Tag(text: s.title.uppercased(), tint: Theme.Palette.accent)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(s.blurb).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                ForEach(s.categories) { c in
                    ForEach(app.readiness.snapshot.items(in: c)) { item in
                        HStack(spacing: Theme.Spacing.s) {
                            Text(item.name).font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary)
                            Spacer(minLength: 0)
                            Tag(text: item.state.label, tint: stateTint(item.state))
                            if let a = item.action, !a.isInstall { Button(a.title.uppercased()) { Task { _ = await ReadinessActions.run(a, in: app) } }.buttonStyle(.hudSecondary).fixedSize() }
                        }
                    }
                }
                HStack {
                    if stage > 0 { Button("BACK") { stage -= 1 }.buttonStyle(.hudSecondary).fixedSize() }
                    Spacer()
                    Button("SKIP SETUP") { app.preferences.firstRunCompleted = true }.buttonStyle(.hudSecondary).fixedSize().accessibilityIdentifier("firstrun.skip")
                    if stage < Self.stages.count - 1 { Button("NEXT") { stage += 1 }.buttonStyle(.hudPrimary).fixedSize().accessibilityIdentifier("firstrun.next") }
                    else { Button("FINISH") { app.preferences.firstRunCompleted = true }.buttonStyle(.hudPrimary).fixedSize().accessibilityIdentifier("firstrun.finish") }
                }
            }
        }
        .accessibilityIdentifier("firstrun.card")
    }
}
