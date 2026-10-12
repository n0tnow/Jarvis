import AppKit
import SwiftUI

/// Settings → Web research (V0.9). Research only happens when you ask; this is where you can switch it off, limit it to plain HTTP and manage the download quarantine.
struct WebResearchSettingsSection: View {
    @Environment(AppContext.self) private var app
    @State private var confirmDelete = false
    @State private var bytes = 0

    var body: some View {
        @Bindable var prefs = app.preferences
        Section("Web research") {
            Toggle("Allow web research and downloads on request", isOn: $prefs.webResearchEnabled).accessibilityIdentifier("settings.webResearch")
            Text("JARVIS searches and reads PUBLIC pages only when you ask it to (typed or spoken), writes a cited report and never crawls in the background. It does not sign in, accept terms, claim assets, read your browser's cookies or passwords, bypass CAPTCHAs or buy anything. No paid search API and no API key is used.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use the built-in browser for pages that need JavaScript", isOn: $prefs.webBrowserTierEnabled).disabled(!prefs.webResearchEnabled)
            Text("A throw-away browser view with an empty, non-persistent profile (nothing is stored, no cookies are kept). It only reads the page; it never types, clicks or signs in. Off = plain HTTP only.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Download quarantine") { Text(app.research.map { _ in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) } ?? "—").font(.system(.caption, design: .monospaced)) }
            Text("Downloads are stored ONLY here (not in any project), hashed and inspected; “downloaded” never means “trusted”, and nothing in it is ever run or imported without a separate task and your approval.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Show in Finder") { if let r = app.research { NSWorkspace.shared.open(r.paths.acquisitions) } }.disabled(app.research == nil)
                Button("Delete downloaded files…") { confirmDelete = true }.disabled(bytes == 0)
            }
            .confirmationDialog("Delete everything in the download quarantine?", isPresented: $confirmDelete) {
                Button("Delete downloaded files", role: .destructive) {
                    if let r = app.research { app.researchModel.purgeQuarantine(r) }
                    bytes = app.research?.acquisition.quarantineBytes() ?? 0
                }
            } message: { Text("Imported copies inside projects are not touched. Acquisition records stay, marked as deleted.") }
        }
        .onAppear { bytes = app.research?.acquisition.quarantineBytes() ?? 0 }
    }
}
