import Foundation
import Testing
@testable import Jarvis

// V1.0 final integration — an accelerated, deterministic soak of the REAL TaskEngine with the engineering seam: many software-engineering tasks with scripted workers of every temperament (good, broken, tampering,
// claiming without changing, failing provider, cancelled mid-flight, racing with someone else's edit, starting on the user's dirty tree). No real waiting beyond the fixtures' own sub-second test runs. The invariants
// are the milestone's: 0 illegal completions, 0 silent paid-provider use, 0 unbounded loops, 0 work after a cancel, bounded growth.
// This is a simulation of WORKERS around the real engine; it is not a macOS run and not a real provider.

private enum Temperament: String, CaseIterable { case good, broken, tampering, noEdit, providerFails, cancelled, stale, dirty }

private func pythonTestsPass(in dir: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-B", "-m", "unittest", "discover"]   // -B: no stale bytecode (an edit within the same second and size would otherwise keep the old .pyc)
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

@Suite("V1.0 final integration · accelerated engineering soak on the real TaskEngine", .serialized)
@MainActor
struct EngineeringFinalSoakTests {
    @Test("sixteen tasks, eight worker temperaments, one engine: no illegal completion, bounded attempts, nothing after a cancel, every lease released, no paid provider")
    func soak() async throws {
        let base = Scripts.standard()
        let removeTest = "<<<<<<< SEARCH test_calc.py\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n=======\n    def test_add(self):\n        pass\n>>>>>>> REPLACE\n"
        let h = TaskHarness()
        var projects: [String: String] = [:]                       // tag → project
        var cancelledJobCounts: [String: Int] = [:]
        func tagOf(_ prompt: String) -> String? {
            guard let r = prompt.range(of: #"\[(good|broken|tampering|noEdit|providerFails|cancelled|stale|dirty)-\d\]"#, options: .regularExpression) else { return nil }
            return String(prompt[r].dropFirst().dropLast())
        }
        h.runner.script = { job, index in
            guard job.type == "CodingAgent" else { return await base(job, index) }
            let tag = tagOf(job.prompt) ?? "good-0"
            switch Temperament(rawValue: String(tag.prefix { $0 != "-" }))! {
            case .good, .dirty: return .text(TaskFixtures.fixEdit)
            case .broken: return .text(Scripts.addEdit(from: ["-", "*", "/", "%"][min(index % 3, 2)], to: ["*", "/", "%", "%"][min(index % 3, 2)]))
            case .tampering: return .text(removeTest)
            case .noEdit: return .text("{\"status\":\"done\",\"filesChanged\":[\"calc.py\"],\"tests\":{\"allGreen\":true}}")
            case .providerFails: return .fail(.generic)
            case .cancelled: return .block
            case .stale:
                if let p = projects[tag] { TaskFixtures.write("README.md", "# edited by somebody else\n", in: p) }
                return .text(TaskFixtures.fixEdit)
            }
        }
        var illegal = 0, completed = 0, failed = 0, cancelled = 0, maxCoding = 0, maxJobs = 0
        for round in 0..<2 {
            for t in Temperament.allCases {
                let tag = "\(t.rawValue)-\(round)"
                let project = TaskFixtures.calculatorProject()
                projects[tag] = project
                if t == .dirty { TaskFixtures.write("README.md", "# my uncommitted notes \(round)\n", in: project) }
                let id = await h.submit("Fix the failing calculation test [\(tag)]", project: project)
                if t == .cancelled {
                    let reached = await h.waitUntil { h.runner.jobs.contains { $0.job.taskID == id && $0.job.type == "CodingAgent" } }
                    #expect(reached)
                    h.engine.cancel(id)
                    let jobsAtCancel = h.runner.jobs.filter { $0.job.taskID == id }.count
                    await h.engine.waitUntilFinished(id)
                    cancelledJobCounts[tag] = h.runner.jobs.filter { $0.job.taskID == id }.count - jobsAtCancel
                } else { await h.engine.waitUntilFinished(id) }
                let task = h.task(id)
                let report = h.engine.report(for: id)
                let mine = h.runner.jobs.filter { $0.job.taskID == id }
                maxCoding = max(maxCoding, mine.filter { $0.job.type == "CodingAgent" }.count); maxJobs = max(maxJobs, mine.count)
                switch task.state {
                case .completed:
                    completed += 1
                    // the only legal completions: a verified fix that really passes, with the user's own work intact
                    if report?.verification != "verified" || !pythonTestsPass(in: project) { illegal += 1 }
                    if t == .dirty { #expect(TaskFixtures.read("README.md", in: project) == "# my uncommitted notes \(round)\n") }
                case .failed: failed += 1
                case .cancelled: cancelled += 1
                default: Issue.record("task \(tag) ended in \(task.state)")
                }
                // a task that did not complete never claimed to
                if task.state != .completed { #expect(report?.verification != "verified" && !(report?.userSummary.contains("completed") ?? false), Comment(rawValue: "\(tag): \(report?.userSummary ?? "")")) }
                // temperaments that must never complete
                if [.broken, .tampering, .noEdit, .providerFails, .cancelled, .stale].contains(t) { #expect(task.state != .completed, Comment(rawValue: "\(tag) completed: \(report?.userSummary ?? "")")) }
                if t == .good || t == .dirty { #expect(task.state == .completed, Comment(rawValue: "\(tag): \(task.failureReason ?? "")")) }
            }
        }
        #expect(illegal == 0, "illegal completions")
        #expect(completed == 4 && cancelled == 2 && failed == 10, Comment(rawValue: "completed \(completed) failed \(failed) cancelled \(cancelled)"))
        #expect(maxCoding <= TaskEngine.maxStepAttempts && maxJobs <= EngineeringBudget().providerRequests, Comment(rawValue: "coding \(maxCoding) jobs \(maxJobs)"))
        #expect(cancelledJobCounts.values.allSatisfy { $0 == 0 }, "no worker or reviewer was asked after a cancel")
        #expect(h.leases.activeCount == 0 && h.persistedActiveLeases == 0 && h.hub.activeRuns.isEmpty, "no orphan work")
        for j in h.runner.jobs { #expect(!LocalModelPolicy.evaluate(j.job.profile).eligible); #expect([.openCode, .claudeCode].contains(j.candidate.engine), "only the harness's declared free / subscription candidates were ever used") }
        let events = try h.database.readOne("SELECT count(*) AS n FROM activity_events")?.int("n") ?? 0
        #expect(events <= JarvisRepository.activityRetention + 1, "the activity history stays bounded (\(events))")
    }
}
