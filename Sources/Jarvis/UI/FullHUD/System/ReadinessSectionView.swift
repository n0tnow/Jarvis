import SwiftUI

// MARK: - System & Readiness (V0.15): “what is ready?” — read on appear and on Recheck, never polled. Buttons map to the closed `SetupAction` list.

private func stateTint(_ s: ReadinessState) -> Color {
    switch s {
    case .ready: Theme.Palette.mint
    case .available, .notRunning: Color.jarvisSecondary
    case .optionalAbsent, .unknown: Color.jarvisTertiary
    case .notInstalled, .signInRequired, .permissionNeeded, .degraded, .stale, .unavailable: Theme.Palette.amber
    }
}

struct ReadinessPanel: View {
    @Environment(AppContext.self) private var app
    @State private var message: String?
    @State private var confirming: SetupAction?
    @State private var busy = false

    var body: some View {
        let snap = app.readiness.snapshot
        VStack(spacing: Theme.Spacing.m) {
            if !app.preferences.firstRunCompleted, AppInfo.isApplicationBundle, !app.intelligenceIsStubbed { FirstRunCard() }
            HUDCard("Readiness") {
                HStack(spacing: Theme.Spacing.s) {
                    Button("RECHECK") { Task { busy = true; await ReadinessActions.recheck(app); busy = false; message = "Checked again." } }
                        .buttonStyle(.hudSecondary).fixedSize().disabled(busy || app.setupRunner.isRunning)
                        .accessibilityHint("Reads the current state again. Starts nothing and installs nothing.").accessibilityIdentifier("readiness.recheck")
                }
            } content: {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text(snap.summary.headline).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary).accessibilityIdentifier("readiness.summary")
                    Text("This only reads the installed state. “Installed”, “signed in” and “running” are different things, and a provider counts as READY only after a safe status check that makes no model request.")
                        .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                    if let m = message { Text(m).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.accent).accessibilityLabel("Result: \(m)") }
                    if app.setupRunner.state != .idle { SetupProgressView() }
                    ForEach(ReadinessCategory.allCases) { cat in
                        let items = snap.items(in: cat)
                        if !items.isEmpty {
                            Text(cat.rawValue.uppercased()).font(Theme.Typography.label).foregroundStyle(Color.jarvisTertiary).padding(.top, Theme.Spacing.xs)
                            ForEach(items) { item in row(item) }
                        }
                    }
                }
            }
        }
        .onAppear { app.readiness.refresh(); Task { await app.voice.refreshProviders(); await app.notifier.refreshStatus(); app.readiness.refresh() } }
        .alert(item: Binding(get: { confirming.map { ConfirmItem(action: $0) } }, set: { confirming = $0?.action })) { c in
            let plan = SetupCatalog.plan(for: c.action)
            return Alert(title: Text(plan?.title ?? c.action.title),
                         message: Text(plan.map { "Source: \($0.source).\nDownload ≈ \(SetupRefusal.gb($0.downloadBytes)), installed ≈ \(SetupRefusal.gb($0.installedBytes)).\nWhere: \($0.destination).\nNothing starts until you press Set Up; you can cancel while it runs. An existing valid installation is reused, not downloaded again." } ?? ""),
                         primaryButton: .default(Text("Set Up")) { Task { message = await ReadinessActions.run(c.action, in: app); app.readiness.refresh() } },
                         secondaryButton: .cancel())
        }
    }

    private struct ConfirmItem: Identifiable { let action: SetupAction; var id: String { action.rawValue } }

    private func row(_ item: ReadinessItem) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                if !item.detail.isEmpty { Text(item.detail).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).fixedSize(horizontal: false, vertical: true) }
                if let note = item.state.detailNote { Text(note).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
            }
            Spacer(minLength: Theme.Spacing.s)
            Tag(text: item.state.label, tint: stateTint(item.state))
            if let a = item.action {
                Button(a.title.uppercased()) { act(a) }.buttonStyle(.hudSecondary).fixedSize().disabled(a.isInstall && app.setupRunner.isRunning)
                    .accessibilityIdentifier("readiness.\(item.id).\(a.rawValue)")
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
