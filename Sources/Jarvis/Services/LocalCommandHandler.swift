import Foundation

/// V0.1 command handling: purely local. No LLM, no network, no intent parsing.
/// The text is recorded in the activity feed and, when idle, triggers a harmless demo state transition.
/// V0.2 will replace this with a real command router behind the same `submit` entry point.
@MainActor
final class LocalCommandHandler {
    private unowned let store: JarvisStore
    private var demoTask: Task<Void, Never>?

    init(store: JarvisStore) {
        self.store = store
    }

    func submit(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        store.log(text, kind: .command)

        // Only run the cosmetic transition from a calm state, so we never interrupt real-looking work.
        guard store.state == .idle || store.state == .completed else {
            store.log("Command stored locally (no intelligence connected in V0.1)", kind: .system)
            return
        }

        demoTask?.cancel()
        store.setState(.thinking)
        demoTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self, self.store.state == .thinking else { return }
            self.store.log("Demo response: command stored locally. No AI is connected in V0.1.", kind: .system)
            self.store.setState(.completed)
        }
    }
}
