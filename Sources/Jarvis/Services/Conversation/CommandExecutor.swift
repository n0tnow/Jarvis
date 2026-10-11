import Foundation

struct ExecutionResult: Equatable, Sendable {
    var message: String
    var tone: MessageTone = .normal
    /// The command already changed the visible HUD surface (e.g. opened the Full HUD).
    var changedWindows = false
}

/// HOW the application performs an intent. Contains no parsing. Window changes go ONLY through
/// `JarvisWindowControlling` (which owns the Compact-XOR-Full invariant); task changes go through `JarvisStore`.
/// Voice and LLM tool calls will call this same type.
@MainActor
final class CommandExecutor {
    private let store: JarvisStore
    private let windows: any JarvisWindowControlling
    private let clearConversation: () -> Void
    /// Returns true if a provider answer was actually being generated (and is now being stopped).
    private let cancelGeneration: () -> Bool

    init(store: JarvisStore, windows: any JarvisWindowControlling, clearConversation: @escaping () -> Void,
         cancelGeneration: @escaping () -> Bool = { false }) {
        self.store = store
        self.windows = windows
        self.clearConversation = clearConversation
        self.cancelGeneration = cancelGeneration
    }

    func execute(_ intent: JarvisIntent, language l: ReplyLanguage) -> ExecutionResult {
        switch intent {
        case .openSection(let section):
            windows.showFullHUD(section: section)
            store.log("Opened \(section.title.capitalized)", kind: .info)
            return ExecutionResult(message: Phrasebook.opening(section, l), changedWindows: true)

        case .openSettings:
            windows.showSettings()
            return ExecutionResult(message: Phrasebook.openingSettings(l), changedWindows: true)

        case .openCompactHUD:
            windows.showCompactHUD()
            return ExecutionResult(message: Phrasebook.compactShown(l), changedWindows: true)

        case .openFullHUD:
            windows.showFullHUD(section: nil)
            return ExecutionResult(message: Phrasebook.fullShown(l), changedWindows: true)

        case .closeHUD:
            windows.hideCompactHUD()
            windows.hideFullHUD()
            return ExecutionResult(message: Phrasebook.hudClosed(l), changedWindows: true)

        case .clearConversation:
            clearConversation()
            return ExecutionResult(message: Phrasebook.cleared(l))

        case .cancelGeneration:
            return cancelGeneration() ? ExecutionResult(message: Phrasebook.generationStopped(l))
                                      : ExecutionResult(message: Phrasebook.nothingGenerating(l), tone: .notice)

        case .showStatus:
            return ExecutionResult(message: statusMessage(l))

        case .pauseTask:
            guard let task = store.activeTask else { return notice(Phrasebook.noTask("pause", l)) }
            if task.engine != nil { return notice(Phrasebook.cannotPauseAutonomous(l)) }
            switch task.status {
            case .running: store.pauseActiveTask(); return ExecutionResult(message: Phrasebook.paused(task.title, l))
            case .paused: return notice(Phrasebook.alreadyPaused(l))
            default: return notice(Phrasebook.needsApproval(task.title, l))
            }

        case .resumeTask:
            guard let task = store.activeTask else { return notice(Phrasebook.noTask("resume", l)) }
            switch task.status {
            case .paused, .interrupted: store.resumeActiveTask(); return ExecutionResult(message: Phrasebook.resumed(task.title, l))
            case .running: return notice(Phrasebook.alreadyRunning(l))
            default: return notice(Phrasebook.needsApproval(task.title, l))
            }

        case .stopTask:
            guard let task = store.activeTask else { return notice(Phrasebook.noTask("stop", l)) }
            store.stopActiveTask()
            return ExecutionResult(message: Phrasebook.stopped(task.title, l))
        }
    }

    /// Built from the real store — never hard-coded.
    func statusMessage(_ l: ReplyLanguage) -> String {
        guard let task = store.activeTask else { return Phrasebook.statusNoTask(store.state.label, l) }
        let step = task.currentStepNumber ?? task.steps.count
        switch task.status {
        case .paused:
            return Phrasebook.statusPaused(task.title, step: step, of: task.steps.count, l)
        case .interrupted:
            return Phrasebook.statusInterrupted(task.title, step: step, of: task.steps.count, l)
        case .waiting:
            return Phrasebook.statusWaiting(task.title, request: store.pendingApproval?.title, l)
        default:
            return Phrasebook.statusWorking(task.title, step: step, of: task.steps.count, stepTitle: task.currentStep?.title ?? "—", l)
        }
    }

    private func notice(_ text: String) -> ExecutionResult { ExecutionResult(message: text, tone: .notice) }
}
