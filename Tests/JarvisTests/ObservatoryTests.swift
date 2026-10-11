import Testing
import Foundation
@testable import Jarvis

private let askText = "Explain this Swift function: func f(_ xs: [Int]) -> Int { xs.reduce(0, +) }"

private func plainView(_ engine: ProviderID = .openCode, phase: RunPhase = .running, owner: RunOwner = .agent) -> AgentRunView {
    AgentRunView(id: UUID(), label: "Task", agentType: "Agent", engine: engine, model: nil, parent: nil, phase: phase, startedAt: Date(), activity: "Working", owner: owner)
}

// MARK: - Progress truth

@Suite("Progress is never invented")
struct ProgressTruthTests {
    private func steps(_ states: [StepState], weights: [Double]? = nil) -> [AgentStep] {
        states.enumerated().map { AgentStep(index: $0.offset, title: "s\($0.offset)", weight: weights?[$0.offset] ?? 1, state: $0.element) }
    }

    @Test func noStructuredStepsMeansNoPercentageAtAll() {
        let p = ProgressCalculator.compute([])
        #expect(p.fraction == nil && p.source == .unknown && !p.isMeasurable && p.label == nil && p == .unknown)
    }

    @Test func threeOfFiveEquallyWeightedStepsIsExactlySixtyPercent() {
        let p = ProgressCalculator.compute(steps([.done, .done, .done, .active, .pending]))
        #expect(p.source == .structuredSteps && p.fraction == 0.6 && p.completed == 3 && p.total == 5 && p.label == "3 / 5 steps" && p.activeTitle == "s3")
    }

    @Test func weightedStepsGiveADeterministicFraction() {
        let p = ProgressCalculator.compute(steps([.done, .done, .active, .pending], weights: [1, 2, 3, 2]))
        #expect(p.source == .weightedSteps && p.fraction == 3.0 / 8.0 && p.completed == 2)
    }

    @Test func failedStepsAreNotCompletedAndSkippedStepsAreNotMeasurableWork() {
        #expect(ProgressCalculator.compute(steps([.done, .failed, .pending])).fraction == 1.0 / 3.0)
        #expect(ProgressCalculator.compute(steps([.done, .skipped, .pending])).fraction == 0.5 && ProgressCalculator.compute(steps([.skipped, .skipped])) == .unknown)
    }

    @Test func invalidWeightsAreNeverGuessedAround() {
        #expect(ProgressCalculator.compute(steps([.done, .pending], weights: [1, 0])) == .unknown)
        #expect(ProgressCalculator.compute(steps([.done, .pending], weights: [1, -2])) == .unknown)
        #expect(ProgressCalculator.compute(steps([.done, .pending], weights: [1, .infinity])) == .unknown)
    }

    @MainActor @Test func aProviderSayingNinetyPercentCompleteDoesNotBecomeNinetyPercent() {
        let hub = ExecutionHub(repository: nil, artifacts: nil)
        let v = plainView(); hub.begin(v)
        hub.appendOutput(v.id, "Progress: 90% complete. Almost done — 90%!\n")
        hub.setActivity(v.id, "90% complete")
        let after = hub.run(v.id)!
        #expect(after.progress == .unknown && after.progress.fraction == nil && after.steps.isEmpty)
        // …while the very same run with real steps shows real progress.
        hub.setSteps(v.id, [("a", 1), ("b", 1), ("c", 1), ("d", 1)]); hub.setStep(v.id, index: 0, .done)
        #expect(hub.run(v.id)?.progress.fraction == 0.25)
    }

    @MainActor @Test func terminalStatesAreReportedAsTheyAreAndNeverGoBackToRunning() {
        let hub = ExecutionHub(repository: nil, artifacts: nil)
        for (phase, label) in [(RunPhase.completed, "Completed"), (.failed, "Failed (timeout)"), (.cancelled, "Cancelled"), (.interrupted, "Interrupted")] {
            let v = plainView(); hub.begin(v)
            hub.finish(v.id, phase: phase, errorCategory: phase == .failed ? "timeout" : nil)
            #expect(hub.run(v.id)?.phase == phase && hub.run(v.id)?.activity == label && hub.run(v.id)?.finishedAt != nil)
            hub.setPhase(v.id, .running, activity: "again")                                         // ignored: finished runs stay finished
            #expect(hub.run(v.id)?.phase == phase)
        }
        #expect(hub.activeRuns.isEmpty)
    }

    @MainActor @Test func progressSourceAndStepsArePersistedAndReadBackFaithfully() throws {
        let h = IntelligenceHarness()
        let id = h.audit.begin(agentType: "BenchmarkAgent", engine: .openCode, model: "opencode/x", decision: nil, prompt: "p", privacy: .normal, label: "Benchmark", owner: .benchmark)
        h.hub.setSteps(id, (0..<5).map { ("step \($0)", 1.0) })
        for i in 0..<3 { h.hub.setStep(id, index: i, .done) }
        h.hub.setStep(id, index: 3, .active)
        let rec = try #require(try h.repo.agentRun(id))
        #expect(rec.progressSource == .structuredSteps && rec.stepsTotal == 5 && rec.stepsDone == 3 && rec.progressFraction == 0.6 && rec.activity == "step 3")
        let view = AgentObservatory.view(from: rec)
        #expect(view.progress.fraction == 0.6 && view.progress.source == .structuredSteps && view.progress.label == "3 / 5 steps")
        let steps = try h.repo.steps(runID: id)
        #expect(steps.count == 5 && steps.filter { $0.state == .done }.count == 3 && steps[3].state == .active)
        // A run without steps persists as unknown with no fraction.
        let plain = h.audit.begin(agentType: "A", engine: .local, model: nil, decision: nil, prompt: "p", privacy: .normal)
        let rec2 = try #require(try h.repo.agentRun(plain))
        #expect(rec2.progressSource == .unknown && rec2.progressFraction == nil && AgentObservatory.view(from: rec2).progress == .unknown)
    }
}

// MARK: - Provider vs agent vs active

@MainActor
@Suite("Provider and agent state tell the truth", .serialized)
struct ProviderAgentStateTests {
    private func resolve(_ e: ProviderID, _ s: ProviderState, active: Int = 0, local: LocalRuntimeState? = nil, cooldown: Date? = nil) -> ProviderUIState {
        ProviderStateResolver.resolve(engine: e, availability: EngineAvailability(e, state: s, cooldownUntil: cooldown), localState: local, activeRuns: active, now: RouteFixtures.now)
    }

    @Test func readyIsNotRunningAndOnlyAnExecutionInFlightIsRunning() {
        #expect(resolve(.claudeCode, .ready) == .ready)                                               // authenticated ≠ consuming quota
        #expect(resolve(.openCode, .ready) == .ready)                                                 // installed + verified ≠ an agent running
        #expect(resolve(.openCode, .ready, active: 1) == .running && resolve(.openCode, .ready, active: 3) == .running)
        #expect(resolve(.codex, .authenticationRequired) == .authRequired && resolve(.codex, .rateLimited(until: nil)) == .rateLimited)
        #expect(resolve(.codex, .notInstalled) == .notInstalled && resolve(.claudeCode, .failed("x")) == .failed && resolve(.claudeCode, .unknown) == .checking)
        #expect(resolve(.openCode, .unavailable("x")) == .unavailable)
    }

    @Test func aDownloadedLocalModelIsUnloadedUntilTheRuntimeIsReallyLoaded() {
        #expect(resolve(.local, .ready, local: .idle) == .unloaded)                                    // files exist, nothing in memory
        #expect(resolve(.local, .ready, local: .ready) == .loadedIdle)
        #expect(resolve(.local, .ready, local: .starting) == .starting && resolve(.local, .running, local: .running) == .running)
        #expect(resolve(.local, .notInstalled, local: .runtimeMissing) == .notInstalled && resolve(.local, .unavailable("m"), local: .modelMissing) == .notInstalled)
        #expect(resolve(.local, .failed("x"), local: .failed("x")) == .failed)
        #expect(resolve(.local, .ready, active: 1, local: .ready) == .running)
    }

    @Test func cooldownIsVisibleAndExpires() {
        #expect(resolve(.openCode, .ready, cooldown: RouteFixtures.now.addingTimeInterval(60)) == .cooldown)
        #expect(resolve(.openCode, .ready, cooldown: RouteFixtures.now.addingTimeInterval(-1)) == .ready)
        #expect(!ProviderUIState.unloaded.explanation.isEmpty && ProviderUIState.unloaded.explanation.contains("automatically"))
    }

    @Test func cardsComeFromRealStateAndHistoryOnlyRunsDoNotLookActive() async throws {
        let h = IntelligenceHarness()
        h.states = [.claudeCode: .ready, .codex: .ready]; h.providerPaths[.codex] = "/x"
        await h.refresh()
        // A finished Codex run exists only as history.
        let old = h.audit.begin(agentType: "ReviewAgent", engine: .codex, model: nil, decision: nil, prompt: "p", privacy: .normal, label: "NetworkPlayer review")
        h.audit.finish(old, status: .succeeded, resultText: "ok")
        let cards = Dictionary(uniqueKeysWithValues: h.observatory.providerCards().map { ($0.id, $0) })
        #expect(cards.count == 4 && cards[.claudeCode]?.state == .ready && cards[.claudeCode]?.activeRuns.isEmpty == true)
        #expect(cards[.codex]?.state == .ready && cards[.codex]?.activeRuns.isEmpty == true && cards[.codex]?.lastRun?.phase == .completed)   // history only
        #expect(cards[.local]?.state == .unloaded)
        #expect(cards[.openCode]?.state == .ready && cards[.openCode]?.facts.contains("1 verified free models available") == true)
        // Two OpenCode agents running → RUNNING with a correct count and the actual model.
        for _ in 0..<2 { h.hub.begin(AgentRunView(id: UUID(), label: "t", agentType: "CodingAgent", engine: .openCode, model: "opencode/alpha-free", parent: nil, phase: .running, startedAt: Date(), activity: "x", owner: .agent)) }
        let oc = try #require(h.observatory.providerCards().first { $0.id == .openCode })
        #expect(oc.state == .running && oc.activeRuns.count == 2 && oc.currentModel == "opencode/alpha-free" && oc.facts.contains("2 active runs"))
        #expect(h.observatory.providerCards().first { $0.id == .codex }?.state == .ready)                // other providers unaffected
    }

    @Test func aProviderFailureAndItsCooldownAreVisibleWithoutSpam() async throws {
        let h = IntelligenceHarness()
        h.installOpenCode(.fail503); h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        await h.ask(askText)
        await h.ask(askText)                                                                        // 2nd failure → cooldown
        let before = (try h.repo.count("activity_events"))
        let oc1 = try #require(h.observatory.providerCards().first { $0.id == .openCode })
        for _ in 0..<20 { _ = h.observatory.providerCards() }                                       // polling/redrawing must not log anything
        #expect(try h.repo.count("activity_events") == before)
        #expect(oc1.lastError == "unavailable" && oc1.lastRun?.phase == .escalated)
        #expect(oc1.cooldownUntil != nil)
        h.shutdown()
    }
}
