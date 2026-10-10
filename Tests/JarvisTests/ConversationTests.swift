import Foundation
import Testing
@testable import Jarvis

// MARK: - Test doubles

@MainActor
final class FakeWindows: JarvisWindowControlling {
    enum Call: Equatable { case showCompact, hideCompact, toggleCompact, showFull(HUDSection?), hideFull, toggleFull, bringForward, settings }
    private(set) var calls: [Call] = []
    var isCompactHUDOpen = false
    var isFullHUDOpen = false
    func showCompactHUD() { calls.append(.showCompact); isCompactHUDOpen = true; isFullHUDOpen = false }
    func hideCompactHUD() { calls.append(.hideCompact); isCompactHUDOpen = false }
    func toggleCompactHUD() { calls.append(.toggleCompact) }
    func showFullHUD(section: HUDSection?) { calls.append(.showFull(section)); isFullHUDOpen = true; isCompactHUDOpen = false }
    func hideFullHUD() { calls.append(.hideFull); isFullHUDOpen = false }
    func toggleFullHUD() { calls.append(.toggleFull) }
    func bringFullHUDForward() { calls.append(.bringForward) }
    func showSettings() { calls.append(.settings) }
}

struct StreamingProvider: IntelligenceProvider {
    let id = "fake"
    let displayName = "Fake"
    var chunks: [String] = ["Hel", "lo ", "there."]
    var delayMs: UInt64 = 5
    func supports(_ kind: IntelligenceRequestKind) -> Bool { true }
    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in chunks {
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    if Task.isCancelled { break }
                    continuation.yield(.textDelta(chunk))
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct FailingProvider: IntelligenceProvider {
    struct Boom: Error {}
    let id = "fail", displayName = "Fail"
    func supports(_ kind: IntelligenceRequestKind) -> Bool { true }
    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: Boom()) }
    }
}

@MainActor
struct Harness {
    let store = JarvisStore()
    let conversation = ConversationStore()
    let windows = FakeWindows()
    let service: ConversationService
    init(providers: IntelligenceProviderRegistry = IntelligenceProviderRegistry()) {
        DemoScenario.seed(store)
        service = ConversationService(store: store, conversation: conversation, windows: windows, providers: providers)
    }
    var replies: [ConversationMessage] { conversation.messages.filter { $0.role == .jarvis } }
}

// MARK: - Normalization

@Suite("Input normalization")
struct NormalizationTests {
    @Test func foldsCaseWhitespaceAndPunctuation() {
        #expect(InputNormalizer.normalize("  OPEN   the   Report!!  ").text == "open report")
        #expect(InputNormalizer.normalize("Open, the... report?").tokens == ["open", "report"])
    }

    @Test func originalIsNeverAltered() {
        let n = InputNormalizer.normalize("  Jarvis, Show me the REPORT!  ")
        #expect(n.original == "  Jarvis, Show me the REPORT!  ")
        #expect(n.text == "show report")
    }

    @Test func stripsOptionalJarvisAddress() {
        for raw in ["Jarvis open the report", "jarvis, open the report", "Hey Jarvis, open the report", "OK Jarvis open the report", "open the report, Jarvis"] {
            let n = InputNormalizer.normalize(raw)
            #expect(n.text == "open report", "\(raw)")
            #expect(n.addressedJarvis)
        }
        #expect(!InputNormalizer.normalize("open the report").addressedJarvis)
        let hey = InputNormalizer.normalize("Hey Jarvis")
        #expect(hey.text.isEmpty && hey.addressedJarvis)
    }

    @Test func turkishFoldingAndDotlessI() {
        #expect(InputNormalizer.normalize("Raporu Aç").text == "raporu ac")
        #expect(InputNormalizer.normalize("Görevleri GÖSTER").text == "gorevleri goster")
        #expect(InputNormalizer.normalize("AYARLARI AÇ").text == "ayarlari ac")
        #expect(InputNormalizer.normalize("Jarvis'i kapat").text == "kapat")
        #expect(InputNormalizer.normalize("İyi akşamlar").text == "iyi aksamlar")
        #expect(InputNormalizer.normalize("raporu aç").language == .tr)
        #expect(InputNormalizer.normalize("open the report").language == .en)
    }

    @Test func removesPoliteLeadInsOnlyWhenSomethingFollows() {
        #expect(InputNormalizer.normalize("Can you pause the task?").text == "pause task")
        #expect(InputNormalizer.normalize("could you please show me the tasks").text == "show tasks")
        #expect(InputNormalizer.normalize("can you").text == "can you")
    }

    @Test func emptyAndSymbolOnlyInput() {
        #expect(InputNormalizer.normalize("   ").tokens.isEmpty)
        #expect(InputNormalizer.normalize("?!...").tokens.isEmpty)
    }
}

// MARK: - Deterministic routing

@Suite("Command router + intelligence router")
struct RoutingTests {
    private let router = IntelligenceRouter()
    private func intent(_ s: String) -> JarvisIntent? {
        if case .command(let i, _) = router.route(s) { return i } else { return nil }
    }

    @Test func reportAliasesResolveConsistently() {
        for s in ["open report", "Open the report.", "show report", "go to report", "show me the report", "Jarvis open the report",
                  "Jarvis, show me the report", "hey jarvis can you open the report", "report", "display the report", "open the report please"] {
            #expect(intent(s) == .openSection(.report), "\(s)")
        }
    }

    @Test func otherSections() {
        #expect(intent("Show my tasks.") == .openSection(.tasks))
        #expect(intent("tasks") == .openSection(.tasks))
        #expect(intent("go to system") == .openSection(.system))
        #expect(intent("Go to system.") == .openSection(.system))
        #expect(intent("show memory") == .openSection(.memory))
        #expect(intent("open dashboard") == .openSection(.dashboard))
        #expect(intent("go home") == .openSection(.dashboard))
        #expect(intent("open settings") == .openSettings)
        #expect(intent("Open settings.") == .openSettings)
        #expect(intent("show task list") == .openSection(.tasks))
    }

    @Test func turkishAliases() {
        #expect(intent("raporu aç") == .openSection(.report))
        #expect(intent("Raporu göster") == .openSection(.report))
        #expect(intent("rapor ver") == .openSection(.report))
        #expect(intent("görevleri göster") == .openSection(.tasks))
        #expect(intent("ayarları aç") == .openSettings)
        #expect(intent("sistemi aç") == .openSection(.system))
        #expect(intent("belleği göster") == .openSection(.memory))
        #expect(intent("ana ekranı aç") == .openSection(.dashboard))
        #expect(intent("görevi duraklat") == .pauseTask)
        #expect(intent("devam et") == .resumeTask)
        #expect(intent("görevi durdur") == .stopTask)
        #expect(intent("durum nedir") == .showStatus)
        #expect(intent("ne yapıyorsun") == .showStatus)
        #expect(intent("sohbeti temizle") == .clearConversation)
        #expect(intent("Jarvis'i kapat") == .closeHUD)
        if case .command(_, let lang) = router.route("raporu aç") { #expect(lang == .tr) } else { Issue.record("not a command") }
    }

    @Test func statusAndTaskControl() {
        for s in ["What are you doing?", "what state are you in", "What's your status?", "status", "Jarvis, what are you working on?"] { #expect(intent(s) == .showStatus, "\(s)") }
        for s in ["Pause the current task.", "pause", "pause task", "Jarvis pause the task", "can you pause the task"] { #expect(intent(s) == .pauseTask, "\(s)") }
        for s in ["Resume the task", "resume", "continue", "continue the task"] { #expect(intent(s) == .resumeTask, "\(s)") }
        for s in ["Stop the current task.", "stop", "cancel task", "abort"] { #expect(intent(s) == .stopTask, "\(s)") }
    }

    @Test func hudCommands() {
        #expect(intent("Close Jarvis.") == .closeHUD)
        #expect(intent("close") == .closeHUD)
        #expect(intent("Jarvis, minimize yourself") == .closeHUD)
        #expect(intent("open compact") == .openCompactHUD)
        #expect(intent("open full hud") == .openFullHUD)
        #expect(intent("open jarvis") == .openFullHUD)
        #expect(intent("clear conversation") == .clearConversation)
        #expect(intent("Clear chat!") == .clearConversation)
    }

    @Test func commandsAreNotMatchedInsideLongerRequests() {
        for s in ["Explain the system architecture", "open the report and tell me about quantum mechanics",
                  "show me the report and the tasks", "what is the main idea of this essay", "tell me about memory management in Swift"] {
            #expect(intent(s) == nil, "\(s)")
        }
    }

    @Test func localReplies() {
        for (s, expected) in [("hello", LocalReply.greeting), ("Hi!", .greeting), ("Hey Jarvis", .greeting), ("hello jarvis", .greeting),
                              ("thanks", .thanks), ("Thank you!", .thanks), ("merhaba", .greeting), ("teşekkürler", .thanks), ("sağol", .thanks)] {
            if case .localResponse(let r, _) = router.route(s) { #expect(r == expected, "\(s)") } else { Issue.record("\(s) not local") }
        }
    }

    @Test func providerRequiredClassification() {
        if case .reasoningRequired = router.route("Explain quantum mechanics.") {} else { Issue.record("expected reasoning") }
        if case .reasoningRequired = router.route("Research the latest NVIDIA model.") {} else { Issue.record("expected reasoning") }
        if case .reasoningRequired = router.route("how are you?") {} else { Issue.record("expected reasoning") }
        if case .workerRequired = router.route("Fix my Unity multiplayer system.") {} else { Issue.record("expected worker") }
        if case .workerRequired = router.route("implement the networking code") {} else { Issue.record("expected worker") }
        #expect(router.route("Explain quantum mechanics.").kind == .reasoning)
    }

    @Test func unsupportedInput() {
        #expect(router.route("?!...").kind == .unsupported)
        #expect(router.route("   ").kind == .unsupported)
    }
}

// MARK: - Execution

@MainActor
@Suite("Command execution")
struct ExecutionTests {
    @Test func navigationGoesThroughWindowControlOnly() {
        let h = Harness()
        h.service.submit("Open the report.")
        #expect(h.windows.calls == [.showFull(.report)])      // exactly one call; exclusivity is the window manager's job
        h.service.submit("show tasks")
        #expect(h.windows.calls.last == .showFull(.tasks))
        h.service.submit("open settings")
        #expect(h.windows.calls.last == .settings)
        h.service.submit("open compact")
        #expect(h.windows.calls.last == .showCompact)
    }

    @Test func closeHidesBothSurfaces() {
        let h = Harness()
        h.service.submit("Close Jarvis.")
        #expect(h.windows.calls == [.hideCompact, .hideFull])
    }

    @Test func deterministicCommandsDoNotChangeJarvisState() {
        let h = Harness()
        h.store.setState(.working)
        let before = h.store.state
        h.service.submit("open the report"); h.service.submit("what are you doing?"); h.service.submit("go to system")
        #expect(h.store.state == before)
    }

    @Test func pauseResumeStopUseRealTask() {
        let h = Harness()
        h.service.submit("Pause the current task.")
        #expect(h.store.activeTask?.status == .paused)
        #expect(h.replies.last?.content.contains("Multiplayer Synchronization") == true)
        h.service.submit("pause")
        #expect(h.replies.last?.content == "The task is already paused.")
        #expect(h.replies.last?.tone == .notice)
        h.service.submit("resume")
        #expect(h.store.activeTask?.status == .running)
        h.service.submit("resume")
        #expect(h.replies.last?.content == "The task is already running.")
        h.service.submit("Stop the task")
        #expect(h.store.activeTask == nil)
        #expect(h.store.tasks.first?.status == .cancelled)
    }

    @Test func noActiveTaskGivesUnderstandableNotice() {
        let h = Harness()
        h.service.submit("stop")
        for cmd in ["pause", "resume", "stop"] {
            h.service.submit(cmd)
            #expect(h.replies.last?.content.hasPrefix("There is no active task to") == true, "\(cmd)")
            #expect(h.replies.last?.tone == .notice)
        }
    }

    @Test func approvalStateIsExplainedNotBypassed() {
        let h = Harness()
        DemoScenario.apply(.waitingForApproval, to: h.store)
        h.service.submit("resume")
        #expect(h.store.activeTask?.status == .waiting)
        #expect(h.replies.last?.content.contains("waiting for your approval") == true)
    }

    @Test func activityLogGetsMeaningfulEventsOnly() {
        let h = Harness()
        let before = h.store.activity.count
        h.service.submit("hello"); h.service.submit("what are you doing?"); h.service.submit("Explain quantum mechanics.")
        #expect(h.store.activity.count == before)                         // no noise from chatter
        h.service.submit("open the report")
        #expect(h.store.activity.last?.message == "Opened Report")
        h.service.submit("pause the task")
        #expect(h.store.activity.last?.message.hasPrefix("Paused") == true)
    }

    @Test func statusIsBuiltFromRealState() {
        let h = Harness()
        h.service.submit("What are you doing?")
        #expect(h.replies.last?.content == "I'm working on “Multiplayer Synchronization” — step 4 of 6: Compile.")
        h.store.pauseActiveTask()
        h.service.submit("status")
        #expect(h.replies.last?.content == "“Multiplayer Synchronization” is paused at step 4 of 6.")
        h.store.stopActiveTask()
        h.service.submit("status")
        #expect(h.replies.last?.content.hasPrefix("No active task. My state is") == true)
        let h2 = Harness()
        DemoScenario.apply(.waitingForApproval, to: h2.store)
        h2.service.submit("status")
        #expect(h2.replies.last?.content.contains("waiting for your approval") == true)
        #expect(h2.replies.last?.content.contains("Run multiplayer tests") == true)
    }

    @Test func turkishCommandsExecuteAndReplyInTurkish() {
        let h = Harness()
        h.service.submit("raporu aç")
        #expect(h.windows.calls == [.showFull(.report)])
        #expect(h.replies.last?.content == "Raporu açıyorum.")
        h.service.submit("görevi duraklat")
        #expect(h.store.activeTask?.status == .paused)
    }
}

// MARK: - Conversation flow

@MainActor
@Suite("Conversation service + store")
struct ConversationFlowTests {
    @Test func appendOrderIsUserThenJarvis() {
        let h = Harness()
        h.service.submit("hello"); h.service.submit("open report"); h.service.submit("status")
        #expect(h.conversation.messages.map(\.role) == [.user, .jarvis, .user, .jarvis, .user, .jarvis])
        #expect(h.conversation.messages.first?.content == "hello")           // original text stored
        #expect(h.conversation.messages.map(\.route).compactMap { $0 } == [.local, .command, .command])
        let times = h.conversation.messages.map(\.timestamp)
        #expect(times == times.sorted())
    }

    @Test func blankSubmissionDoesNothing() {
        let h = Harness()
        #expect(h.service.submit("") == nil)
        #expect(h.service.submit("   \n\t ") == nil)
        #expect(h.conversation.messages.isEmpty && h.windows.calls.isEmpty)
    }

    @Test func originalTextIsStoredNotTheNormalizedForm() {
        let h = Harness()
        h.service.submit("  Jarvis, SHOW me the Report!  ")
        #expect(h.conversation.messages.first?.content == "Jarvis, SHOW me the Report!")   // trimmed only
    }

    @Test func manySubmissionsKeepOrderAndNeverCorrupt() {
        let h = Harness()
        for i in 0..<100 { h.service.submit(i % 2 == 0 ? "status" : "hello") }
        #expect(h.conversation.messages.count == 200)
        #expect(h.conversation.messages.enumerated().allSatisfy { ($0.offset % 2 == 0) == ($0.element.role == .user) })
        #expect(h.windows.calls.isEmpty)
    }

    @Test func storeIsBounded() {
        let store = ConversationStore()
        for i in 0..<(ConversationStore.capacity + 25) { store.appendUser("m\(i)") }
        #expect(store.messages.count == ConversationStore.capacity)
        #expect(store.messages.first?.content == "m25")
    }

    @Test func veryLongInputIsBoundedNotRejected() {
        let h = Harness()
        h.service.submit(String(repeating: "x", count: 20_000))
        #expect(h.conversation.messages.first?.content.count == ConversationStore.maxMessageLength)
    }

    @Test func clearConversation() {
        let h = Harness()
        h.service.submit("hello"); h.service.submit("hi")
        h.service.submit("clear conversation")
        #expect(h.conversation.messages.count == 1)                                  // only the confirmation
        #expect(h.conversation.messages.first?.content == "Conversation cleared.")
    }

    @Test func reasoningRequestIsTruthfulAndMakesNoProviderCall() {
        let h = Harness()
        let decision = h.service.submit("Explain quantum mechanics.")
        #expect(decision?.kind == .reasoning)
        let reply = h.replies.last
        #expect(reply?.content.contains("none is connected yet") == true)
        #expect(reply?.tone == .notice && reply?.route == .reasoning && reply?.status == .complete)
        #expect(h.store.state == .idle)                                    // no fake "thinking"
        #expect(h.windows.calls.isEmpty)                                   // from the Full HUD: stays put
        h.service.submit("Fix my Unity multiplayer system.")
        #expect(h.replies.last?.route == .worker)
        #expect(h.replies.last?.content.contains("Nothing was started") == true)
    }

    @Test func compactOriginReasoningContinuesInFullHUD() {
        let h = Harness()
        h.service.submit("Explain quantum mechanics.", origin: .compactHUD)
        #expect(h.windows.calls == [.showFull(.dashboard)])
        let h2 = Harness()
        h2.service.submit("what are you doing?", origin: .compactHUD)          // simple → stays compact
        #expect(h2.windows.calls.isEmpty)
        h2.service.submit("show tasks", origin: .compactHUD)                    // navigation → Full HUD via window control
        #expect(h2.windows.calls == [.showFull(.tasks)])
    }

    @Test func providerStreamingIsSupportedAndNotAtomic() async {
        var registry = IntelligenceProviderRegistry()
        registry.register(StreamingProvider())
        let h = Harness(providers: registry)
        h.service.submit("Explain quantum mechanics.")
        #expect(h.conversation.last?.status == .pending)                 // created before any content
        #expect(h.store.state == .thinking)
        for _ in 0..<200 where h.service.isResponding { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(h.conversation.last?.content == "Hello there.")
        #expect(h.conversation.last?.status == .complete)
        #expect(h.store.state == .idle)
    }

    @Test func providerResponseCanBeCancelledMidStream() async {
        var registry = IntelligenceProviderRegistry()
        registry.register(StreamingProvider(chunks: Array(repeating: "x", count: 200), delayMs: 20))
        let h = Harness(providers: registry)
        h.service.submit("Explain quantum mechanics.")
        try? await Task.sleep(nanoseconds: 120_000_000)
        h.service.cancelCurrentResponse()
        for _ in 0..<200 where h.service.isResponding { try? await Task.sleep(nanoseconds: 10_000_000) }
        let last = h.conversation.last
        #expect(!h.service.isResponding)
        #expect((last?.content.count ?? 0) < 200)                          // stopped early, partial text kept
        #expect(last?.tone == .notice && last?.status == .complete)
        #expect(h.store.state == .idle)
    }

    @Test func providerFailureIsReportedNotThrown() async {
        var registry = IntelligenceProviderRegistry()
        registry.register(FailingProvider())
        let h = Harness(providers: registry)
        h.service.submit("Explain quantum mechanics.")
        for _ in 0..<200 where h.service.isResponding { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(h.conversation.last?.status == .failed)
        #expect(h.conversation.last?.content == "The intelligence provider failed.")
        #expect(h.store.state == .idle)
    }

    @Test func v02RegistersNoProvider() {
        #expect(IntelligenceProviderRegistry().provider(for: .reasoning) == nil)
        #expect(IntelligenceProviderRegistry().provider(for: .worker) == nil)
    }
}
