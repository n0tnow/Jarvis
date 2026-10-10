import Foundation
import Testing
@testable import Jarvis

@Suite("JarvisTask")
struct TaskModelTests {
    @Test func progressIsDerivedFromSteps() {
        let task = DemoData.multiplayerTask()
        #expect(task.steps.count == 6)
        #expect(task.completedStepCount == 3)
        #expect(task.progress == 0.5)
        #expect(task.currentStep?.title == "Compile")
        #expect(task.currentStepNumber == 4)
    }

    @Test func progressChangesOnlyWhenStepsChange() {
        var task = DemoData.multiplayerTask()
        task.steps[3].status = .completed
        task.steps[4].status = .active
        #expect(task.completedStepCount == 4)
        #expect(task.currentStep?.title == "Run multiplayer tests")
    }

    @Test func pausingStopsTheClock() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var task = JarvisTask(title: "t", details: "", status: .running, createdAt: t0, steps: [], runningSince: t0)
        task.pause(at: t0.addingTimeInterval(60))
        #expect(task.status == .paused)
        #expect(task.elapsed(at: t0.addingTimeInterval(600)) == 60)
        task.resume(at: t0.addingTimeInterval(600))
        #expect(task.elapsed(at: t0.addingTimeInterval(630)) == 90)
    }

    @Test func cancelledTaskIsNoLongerActive() {
        var task = DemoData.multiplayerTask()
        task.cancel()
        #expect(task.status == .cancelled)
        #expect(!task.status.isActive)
        #expect(task.completedAt != nil)
    }

    @Test func taskRoundTripsThroughCodable() throws {
        let task = DemoData.multiplayerTask()
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(JarvisTask.self, from: data)
        #expect(decoded == task)
    }

    @Test func elapsedFormatting() {
        #expect(ElapsedText.format(75) == "01:15")
        #expect(ElapsedText.format(3_725) == "1:02:05")
    }
}

@MainActor
@Suite("JarvisStore")
struct StoreTests {
    private func makeStore() -> JarvisStore {
        let store = JarvisStore()
        DemoScenario.seed(store)
        return store
    }

    @Test func seededStoreHasActiveDemoTask() {
        let store = makeStore()
        #expect(store.activeTask?.title == "Multiplayer Synchronization")
        #expect(store.activity.count == 5)
    }

    @Test func pauseResumeStop() {
        let store = makeStore()
        store.setState(.working)
        store.pauseActiveTask()
        #expect(store.activeTask?.status == .paused)
        #expect(store.state == .idle)
        store.resumeActiveTask()
        #expect(store.activeTask?.status == .running)
        #expect(store.state == .working)
        store.stopActiveTask()
        #expect(store.activeTask == nil)
    }

    @Test func approvalFlow() {
        let store = makeStore()
        DemoScenario.apply(.waitingForApproval, to: store)
        #expect(store.state == .waitingForApproval)
        #expect(store.activeTask?.status == .waiting)
        #expect(store.pendingApproval != nil)
        store.resolveApproval(approved: true)
        #expect(store.state == .working)
        #expect(store.activeTask?.status == .running)
        #expect(store.pendingApproval == nil)
    }

    @Test func activityIsBounded() {
        let store = makeStore()
        for i in 0..<(JarvisStore.activityCapacity + 50) { store.log("e\(i)") }
        #expect(store.activity.count == JarvisStore.activityCapacity)
    }

    @Test func commandIsRecordedLocally() {
        let store = makeStore()
        let handler = LocalCommandHandler(store: store)
        let before = store.activity.count
        handler.submit("  test  ")
        #expect(store.activity.count == before + 1)
        #expect(store.activity.last?.message == "test")
        #expect(store.activity.last?.kind == .command)
        handler.submit("   ")
        #expect(store.activity.count == before + 1)
    }
}

@MainActor
@Suite("Demo state ↔ task coherence")
struct CoherenceTests {
    private func seeded() -> JarvisStore { let s = JarvisStore(); DemoScenario.seed(s); return s }

    @Test func completedStateCompletesTheTask() {
        let store = seeded()
        DemoScenario.apply(.completed, to: store)
        #expect(store.state == .completed)
        #expect(store.activeTask == nil)
        #expect(store.tasks.first?.status == .completed)
        #expect(store.tasks.first?.steps.allSatisfy { $0.status == .completed } == true)
    }

    @Test func errorStateFailsTheTask() {
        let store = seeded()
        DemoScenario.apply(.error, to: store)
        #expect(store.state == .error)
        #expect(store.activeTask == nil)
        #expect(store.tasks.first?.status == .failed)
        #expect(store.tasks.first?.steps.contains { $0.status == .failed } == true)
    }

    @Test func idleDoesNotLeaveATaskRunning() {
        let store = seeded()
        DemoScenario.apply(.idle, to: store)
        #expect(store.state == .idle)
        #expect(store.activeTask?.status != .running)
    }

    @Test func workingAfterCompletionRestartsADemoTask() {
        let store = seeded()
        DemoScenario.apply(.completed, to: store)
        DemoScenario.apply(.working, to: store)
        #expect(store.state == .working)
        #expect(store.activeTask?.status == .running)
    }

    @Test func leavingApprovalDoesNotStrandTheTask() {
        let store = seeded()
        DemoScenario.apply(.waitingForApproval, to: store)
        DemoScenario.apply(.working, to: store)
        #expect(store.pendingApproval == nil)
        #expect(store.activeTask?.status == .running)
    }

    @Test func allStatesAreCovered() {
        #expect(JarvisState.allCases.count == 7)
        #expect(JarvisState.allCases.filter(\.isAnimated).count == 3)
    }
}
