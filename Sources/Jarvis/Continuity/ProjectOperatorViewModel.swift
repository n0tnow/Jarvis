import Foundation
import Observation

/// What the Project panel shows, read from `ProjectContinuity` on demand (opening the panel, a finished task, the Refresh button). It polls nothing and never writes.
@MainActor
@Observable
final class ProjectOperatorViewModel {
    private let continuity: ProjectContinuity
    private let preferences: Preferences
    private(set) var view: ProjectContinuityView?
    private(set) var report = ReconciliationReport()
    private(set) var busy = false
    private(set) var lastAnswer: String?
    private(set) var loadedRoot: String?

    init(continuity: ProjectContinuity, preferences: Preferences) { self.continuity = continuity; self.preferences = preferences }

    var diagnostics: ContinuityDiagnostics? { continuity.lastDiagnostics }
    var bounds: ContinuationBounds { continuity.bounds }

    func refresh() async {
        let root = preferences.projectRoot
        guard !root.isEmpty, continuity.enabled(), !busy else { if root.isEmpty { view = nil; loadedRoot = nil }; return }
        busy = true; defer { busy = false }
        guard let g = await continuity.gatherCurrent() else { view = nil; return }
        view = g.view; report = g.report; loadedRoot = root
    }

    /// The Continue button is the same explicit user request as saying “continue”: one code path, no extra authority.
    func continueProject() async {
        busy = true
        lastAnswer = await continuity.reply(to: .continueProject(project: nil), language: .en, channel: .typed)
        busy = false
        await refresh()
    }
}
