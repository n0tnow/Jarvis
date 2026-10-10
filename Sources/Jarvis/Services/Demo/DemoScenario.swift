import Foundation

/// Development-only helpers that let us exercise the whole visual state machine without any AI.
/// Used by the developer controls (Compact + Full HUD) and launch arguments.
@MainActor
enum DemoScenario {
    static func seed(_ store: JarvisStore) {
        store.load(
            tasks: DemoData.tasks(),
            activity: DemoData.activity(),
            project: DemoData.project,
            agents: DemoData.agents,
            tools: DemoData.tools
        )
    }

    /// Restores the demo task to its initial mid-run position.
    static func resetDemoTask(_ store: JarvisStore) {
        store.clearPendingApproval()
        store.replaceTasks(DemoData.tasks())
        store.setState(.working)
        store.log("Demo task reset", kind: .system)
    }

    /// Switches the visual state and keeps the demo task coherent with it:
    ///
    /// - idle: nothing running → a running task is paused
    /// - listening / thinking: foreground activity only; a task may keep running in the background
    /// - working / approval: need a live task (a finished one is reset first)
    /// - completed: the task completes · error: the task fails (both end the clock)
    static func apply(_ state: JarvisState, to store: JarvisStore) {
        if state != .waitingForApproval { store.clearPendingApproval() }

        switch state {
        case .idle:
            store.pauseActiveTask()
            store.setState(.idle)
        case .listening, .thinking:
            store.setState(state)
        case .working:
            ensureLiveTask(store)
            if store.activeTask?.status == .paused {
                store.resumeActiveTask()
            } else {
                store.setState(.working)
            }
        case .waitingForApproval:
            ensureLiveTask(store)
            store.requestApproval(DemoData.approval)
        case .completed:
            store.completeActiveTask()
            store.setState(.completed)
        case .error:
            store.failActiveTask()
            store.log("Demo error raised", kind: .error)
            store.setState(.error)
        }
    }

    /// If the demo task already finished/failed/was stopped, bring back a fresh one so "Working" has something to show.
    private static func ensureLiveTask(_ store: JarvisStore) {
        guard store.activeTask == nil else { return }
        store.replaceTasks(DemoData.tasks())
        store.log("Demo task restarted", kind: .system)
    }

    static func addDemoEvent(_ store: JarvisStore) {
        store.log("Demo event #\(store.activity.count + 1)", kind: .info)
    }
}
