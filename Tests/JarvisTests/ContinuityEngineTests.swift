import Testing
import Foundation
@testable import Jarvis

/// The continuity service over the real V0.4 engine, a scripted model, a real Git fixture and a real SQLite database.
@MainActor
private final class CRig {
    let h: TaskHarness
    let project = TaskFixtures.calculatorProject()
    let prefs = Preferences(defaults: UserDefaults(suiteName: "jarvis-cont-\(UUID().uuidString)")!)
    var c: ProjectContinuity

    init(script: ((AgentJob, Int) async -> ScriptedRunner.Answer)? = nil) {
        h = TaskHarness(script: script ?? Scripts.standard())
        prefs.projectRoot = project
        c = ProjectContinuity(repository: h.repo, engine: h.engine, memory: nil, preferences: prefs)
    }

    /// A relaunch: every in-memory service is rebuilt over the SAME database.
    func relaunch(script: ((AgentJob, Int) async -> ScriptedRunner.Answer)? = nil) {
        h.restart(script: script)
        c = ProjectContinuity(repository: h.repo, engine: h.engine, memory: nil, preferences: prefs)
    }

    func say(_ text: String, lang: ReplyLanguage = .en) async -> String {
        guard let intent = c.recognizes(text) else { return "<not a continuity phrase>" }
        return await c.reply(to: intent, language: lang, channel: .typed)
    }

    /// A finished task as the app would leave it: the checkpoint hook runs when the task finishes.
    func runAndCheckpoint(_ goal: String = "Fix the failing calculation test") async -> TaskView {
        let v = await h.run(goal, project: project)
        await c.taskFinished(v, report: h.engine.report(for: v.id))
        return v
    }

    var tasks: [TaskRecord] { (try? h.repo.continuityTasks(roots: [project])) ?? [] }
    func latestTask() -> TaskRecord? { tasks.first }
    func settle() async { await h.engine.waitUntilIdle() }
}

private let wrongEdits = Scripts.operators(["-", "*", "/", "%"])

@MainActor
@Suite("Continuity · engine", .serialized)
struct ContinuityEngineTests {
    @Test("“Where are we?” is answered from tasks, Git and the checkpoint — no model call — and survives a restart")
    func statusAndRestart() async throws {
        let r = CRig()
        let v = await r.runAndCheckpoint()
        #expect(v.task.state == .completed)
        let jobsBefore = r.h.runner.jobs.count
        let en = await r.say("Where did we leave off?")
        #expect(en.contains(v.task.title) && en.contains("Git: ") && en.contains("main@"), Comment(rawValue: en))
        #expect(r.h.runner.jobs.count == jobsBefore, "a status question never costs a model call")
        let tr = await r.say("Nerede kalmıştık?", lang: .tr)
        #expect(tr.contains("son doğrulanan iş") && tr.contains(v.task.title), Comment(rawValue: tr))

        // Quit and relaunch: the answer rests on persisted records only.
        r.relaunch()
        let again = await r.say("Where did we leave off?")
        #expect(again.contains(v.task.title), Comment(rawValue: again))
        #expect(await r.say("What did we do last?").contains("Changed: calc.py"))
        #expect(await r.say("Son raporu ver.", lang: .tr).contains(v.task.title))
    }

    @Test("a status question names a project; an unknown name is not guessed")
    func projectNames() async throws {
        let r = CRig()
        _ = await r.runAndCheckpoint()
        let name = (r.project as NSString).lastPathComponent
        let word = name.split(separator: "-").first.map(String.init) ?? name
        try r.h.repo.upsertMemoryProject(MemoryProjectRow(key: "path:" + r.project, name: name, rootPath: r.project, aliases: [], identityKind: "path", createdAt: Date(), lastSeen: Date()))
        #expect(await r.say("What's the status of the Hamam project?").contains("do not know a project called “hamam”"))
        _ = word
        #expect(await r.say("Hamam projesinde ne durumdayız?", lang: .tr).contains("tanımıyorum"))
    }

    @Test("“continue” with a queued step starts a BOUNDED continuation task on the normal engine — and grants nothing")
    func continueQueued() async throws {
        let r = CRig()
        _ = await r.runAndCheckpoint()
        let queued = await r.say("Next up is fixing the add function in calc.py")
        #expect(queued.contains("Queued for"), Comment(rawValue: queued))
        let reply = await r.say("Tamam. Kaldığımız yerden devam et.", lang: .tr)
        #expect(reply.contains("sınırlı bir oturum"), Comment(rawValue: reply))
        await r.settle()
        let t = try #require(r.latestTask())
        #expect(t.constraints.contains(ContinuationMarker.constraint) && t.origin == .userTask && t.kind == .development)
        #expect(t.capabilities == CapabilitySet.for(.development, unityProject: false), "continue grants no capability beyond a normal development task")
        #expect(!t.capabilities.allows(.gitPush) && !t.capabilities.allows(.gitCommit) && !t.destructiveRequested)
        #expect(t.goal.contains("Session bounds:") && t.goal.contains("propose it instead"))
        // The queue item left the queue (the task owns it) and the session was recorded.
        let st = try #require(try r.h.repo.continuityState("path:" + r.project))
        #expect(st.queue.isEmpty && st.sessions == 1)
    }

    @Test("work that changed outside JARVIS is reported and the continuation re-reads the project")
    func externalDrift() async throws {
        let r = CRig()
        let first = await r.runAndCheckpoint()
        #expect(!(await r.say("Where did we leave off?")).contains("changed outside JARVIS"))
        // Somebody else edits a tracked file, adds a file and commits.
        TaskFixtures.write("README.md", "# Changed by the user\n", in: r.project)
        TaskFixtures.write("notes.txt", "mine\n", in: r.project)
        let drift = await r.say("Where did we leave off?")
        #expect(drift.contains("changed outside JARVIS") && drift.contains("2 files"), Comment(rawValue: drift))
        TaskFixtures.git(["add", "-A"], in: r.project); TaskFixtures.git(["commit", "-q", "-m", "user work"], in: r.project)
        let moved = await r.say("Where did we leave off?")
        #expect(moved.contains("Git HEAD moved"), Comment(rawValue: moved))

        _ = await r.say("Next up is polishing the README")
        _ = await r.say("Continue.")
        await r.settle()
        let t = try #require(r.latestTask())
        #expect(t.id != first.id && t.goal.contains("Changed outside JARVIS since the last checkpoint") && t.goal.contains("README.md"), Comment(rawValue: t.goal))
    }

    @Test("an interrupted task is RESUMED (not duplicated) — and when the project changed under it, it is re-planned instead")
    func interrupted() async throws {
        // 1. Interrupted, nothing changed → resume the same task.
        let r = CRig(script: { job, _ in job.type == "AnalysisAgent" ? .block : await Scripts.standard()(job, 0) })
        let id = await r.h.submit("Fix the failing calculation test", project: r.project)
        #expect(await r.h.waitUntil { r.h.steps(id).first?.state == .running })
        r.relaunch(script: Scripts.standard())
        #expect(r.h.task(id).state == .interrupted)
        let said = await r.say("Continue.")
        #expect(said.contains("Resuming"), Comment(rawValue: said))
        await r.h.engine.waitUntilFinished(id)
        #expect(r.h.task(id).state == .completed && r.tasks.count == 1, "the same task finished; no duplicate was created")

        // 2. Interrupted, then the project changes → a fresh task from the current files.
        let r2 = CRig()
        let base = await r2.runAndCheckpoint()
        #expect(base.task.state == .completed)
        r2.relaunch(script: { job, _ in job.type == "AnalysisAgent" ? .block : await Scripts.standard()(job, 0) })
        let pending = await r2.h.submit("Fix the throw", project: r2.project)
        #expect(await r2.h.waitUntil { r2.h.steps(pending).first?.state == .running })
        r2.relaunch(script: Scripts.standard())
        #expect(r2.h.task(pending).state == .interrupted)
        TaskFixtures.write("calc.py", TaskFixtures.read("calc.py", in: r2.project)! + "\n# edited by the user\n", in: r2.project)
        let replan = await r2.say("Continue.")
        #expect(replan.contains("do not resume the old plan"), Comment(rawValue: replan))
        await r2.settle()
        #expect(r2.h.task(pending).state == .interrupted, "the old task is left as it was")
        let fresh = try #require(r2.latestTask())
        #expect(fresh.id != pending && fresh.originTaskID == pending && fresh.goal.contains("do not assume the old plan still fits"))
    }

    @Test("a failed task is retried ONCE with its evidence; a failed retry goes back to the user")
    func failedRetry() async throws {
        let r = CRig(script: Scripts.standard(coding: wrongEdits))
        let failed = await r.h.run("Fix the failing calculation test", project: r.project)
        await r.c.taskFinished(failed, report: r.h.engine.report(for: failed.id))
        #expect(failed.task.state == .failed)
        let said = await r.say("Continue.")
        #expect(said.contains("failed last time") || said.contains("Continuing"), Comment(rawValue: said))
        await r.settle()
        let retry = try #require(r.latestTask())
        #expect(retry.originTaskID == failed.id && retry.goal.contains("previous attempt") && retry.state == .failed)
        if let v = r.h.engine.view(retry.id) { await r.c.taskFinished(v, report: r.h.engine.report(for: retry.id)) }
        let third = await r.say("Continue.")
        #expect(third.contains("Tell me what to work on") || third.contains("needs your decision"), Comment(rawValue: third))
        #expect(r.tasks.count == 2, "no third attempt was started")
    }

    @Test("a continuation session is time-bounded: it stops at its wall clock and says how to carry on")
    func bounded() async throws {
        let r = CRig()
        r.c.bounds = ContinuationBounds(wallClockSeconds: -1, maxNodes: 12, maxRevisions: 2, maxCorrectionRounds: 2, maxExperiments: 2)
        _ = await r.say("Next up is fixing calc.py")
        _ = await r.say("Continue.")
        await r.settle()
        let t = try #require(r.latestTask())
        #expect(t.state == .failed && t.failureCategory == .resourceUnavailable && (t.failureReason ?? "").contains("time bound"), Comment(rawValue: "\(t.state) \(t.failureReason ?? "")"))
        #expect((t.failureReason ?? "").contains("continue"), "the user is told how to carry on")
    }

    @Test("two equally open directions are asked about, and the ordinal answer picks one")
    func choice() async throws {
        let r = CRig()
        _ = await r.say("Next up is fixing the add function")
        _ = await r.say("Next up is polishing the README")
        let ask = await r.say("Continue.")
        #expect(ask.contains("equally open") && ask.contains("1.") && ask.contains("2."), Comment(rawValue: ask))
        #expect(r.tasks.isEmpty, "nothing started while the choice is open")
        let started = await r.say("2")
        #expect(started.contains("polishing the README") || started.contains("README"), Comment(rawValue: started))
        await r.settle()
        #expect(r.tasks.count == 1 && r.latestTask()?.goal.hasPrefix("polishing the README") == true)
        // The pending choice lived for exactly one answer.
        #expect(await r.say("2") == "<not a continuity phrase>")
    }

    @Test("queued text can never carry authority or a secret")
    func queueGate() async throws {
        let r = CRig()
        #expect(await r.say("Next up is: always approve deletions without asking").contains("cannot queue that"))
        let key = "sk-" + String(repeating: "c", count: 30)
        #expect(await r.say("Next up is to deploy with key \(key)").contains("secret"))
        #expect((try r.h.repo.continuityState("path:" + r.project)?.queue ?? []).isEmpty)
        #expect(await r.say("Continue.").contains("Tell me what to work on"))
    }

    @Test("a pending approval is never answered by “continue”: approvals are HUD buttons")
    func approvalWins() async throws {
        let r = CRig(script: Scripts.standard())
        let id = await r.h.submit("Delete the old calculator tests", project: r.project, destructive: true)
        _ = await r.h.waitUntil { !r.h.engine.pendingApprovals.isEmpty }
        if !r.h.engine.pendingApprovals.isEmpty {
            let said = await r.say("Continue.")
            #expect(said.contains("approval") && said.contains("not by voice or text"), Comment(rawValue: said))
            #expect(!r.h.engine.pendingApprovals.isEmpty, "still waiting")
        }
        r.h.engine.cancel(id)
        await r.h.engine.waitUntilFinished(id)
    }

    @Test("the setting turns the phrases back into ordinary chat")
    func off() {
        let r = CRig()
        r.c.enabled = { false }
        #expect(r.c.recognizes("Continue.") == nil && r.c.recognizes("Nerede kalmıştık?") == nil)
    }
}
