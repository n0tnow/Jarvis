import Foundation
import Observation

/// What the Computer screen shows: the live session (from real state), the action timeline, history, and the permission state. It never shows an Accessibility tree
/// and it never starts anything on its own: the only actions are Stop, Resume and the explicit permission buttons.
@MainActor
@Observable
final class ComputerViewModel {
    let runtime: ComputerRuntime
    let engine: TaskEngine
    let preferences: Preferences
    private(set) var sessions: [ComputerSessionRecord] = []
    private(set) var actions: [ComputerActionRecord] = []
    var selectedSession: UUID? { didSet { loadActions() } }
    var message: String?

    init(runtime: ComputerRuntime, engine: TaskEngine, preferences: Preferences) { self.runtime = runtime; self.engine = engine; self.preferences = preferences }

    var isEnabled: Bool { preferences.computerUseEnabled }
    var permissions: ComputerPermissions { runtime.permissions }

    /// The computer task being shown: the running one, else the most recent.
    var currentTask: TaskView? {
        engine.orderedViews.first { $0.task.kind == .computer && $0.task.state.isActive } ?? engine.orderedViews.first { $0.task.kind == .computer }
    }

    func refresh() {
        runtime.refreshPermissions()
        sessions = (try? engine.repository?.computerSessions(limit: 20)) ?? []
        if selectedSession == nil { selectedSession = currentTask?.id ?? sessions.first?.id } else { loadActions() }
    }

    func revisionChanged() { sessions = (try? engine.repository?.computerSessions(limit: 20)) ?? sessions; loadActions() }

    private func loadActions() {
        guard let id = selectedSession else { actions = []; return }
        actions = (try? engine.repository?.computerActions(sessionID: id)) ?? []
    }

    func stop() {
        guard let t = currentTask, t.task.state.isStoppable else { return }
        runtime.stopAll(reason: "stopped from the HUD")
        engine.cancel(t.id)
        message = "Stopped. The application was left exactly as it is."
    }
    func resume(_ id: UUID) {
        if engine.resume(id) { message = "Resuming: JARVIS looks at everything again before it does anything." } else { message = "That session cannot be resumed (it is not interrupted, or too many tasks are running)." }
    }
    func decide(_ approvalID: UUID, approved: Bool) { engine.decide(approvalID, approved: approved) }
    func guideToAccessibility() { runtime.guideToAccessibility() }
    func guideToScreenCapture() { runtime.guideToScreenCapture() }
}
