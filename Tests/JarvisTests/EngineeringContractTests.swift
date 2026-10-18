import Foundation
import Testing
@testable import Jarvis

// V1.0 autonomous engineering pipeline — the assignment contract, the worker report contract, path classification and Git status parsing. Pure logic; no model, no network.

private func assignment(objective: String = "Make add() in calc.py return the sum instead of the difference", allowed: [String] = ["calc.py"], risk: RiskClass = .low) -> EngineeringAssignment {
    var a = EngineeringAssignment(objective: objective, project: "fixture")
    a.scope.allowed = allowed
    a.acceptance = [AcceptanceCriterion(id: "c1", text: "unit tests pass", check: .profile("python3 -m unittest"))]
    a.risk = risk
    return a
}

@Suite("V1.0 engineering · path globs")
struct PathGlobTests {
    @Test("globs: exact, directory prefix, ** depth, * within a segment, case-insensitive")
    func matching() {
        #expect(PathGlob.matches("Sources/Foo/**", "Sources/Foo/A.swift") && PathGlob.matches("Sources/Foo/**", "Sources/Foo/Deep/B.swift"))
        #expect(!PathGlob.matches("Sources/Foo/**", "Sources/Bar/A.swift") && !PathGlob.matches("Sources/Foo/**", "README.md"))
        #expect(PathGlob.matches("Sources/Foo", "Sources/Foo/A.swift") && PathGlob.matches("calc.py", "calc.py") && !PathGlob.matches("calc.py", "calc.pyc"))
        #expect(PathGlob.matches("*.md", "README.md") && !PathGlob.matches("*.md", "docs/README.md") && PathGlob.matches("**/*.md", "docs/a/README.md"))
        #expect(PathGlob.matches("sources/FOO/**", "Sources/foo/A.swift"))
        #expect(PathGlob.matches("tests/**", "tests/test_x.py") && !PathGlob.matches("tests/**", "src/tests_helper.py"))
        #expect(!PathGlob.matches("", "a") && !PathGlob.matches("a", ""))
    }

    @Test("overlap is conservative: unsure means they may collide")
    func overlap() {
        #expect(PathGlob.mayOverlap("Sources/Foo/**", "Sources/Foo/A.swift") && PathGlob.mayOverlap("Sources", "Sources/Foo/A.swift") && PathGlob.mayOverlap("a.py", "a.py"))
        #expect(!PathGlob.mayOverlap("Sources/Foo/**", "Sources/Bar/**") && !PathGlob.mayOverlap("a.py", "b.py") && !PathGlob.mayOverlap("docs/**", "src/**"))
        #expect(!PathGlob.mayOverlap("**/*.md", "**/*.swift"))
        #expect(PathGlob.mayOverlap("**/*.swift", "Sources/**/*.swift"))
    }
}

@Suite("V1.0 engineering · the assignment contract")
struct EngineeringAssignmentTests {
    @Test("a well-formed assignment validates; vague, empty, unscoped, unverifiable and critical-without-gate ones do not")
    func validation() {
        #expect(assignment().validate().isEmpty)
        #expect(EngineeringAssignment(objective: "   ", project: "p").validate().contains(.emptyObjective))
        var vague = EngineeringAssignment(objective: "fix the project", project: "p"); vague.scope.allowed = []
        #expect(vague.validate().contains(.tooVague))
        var noCriteria = assignment(); noCriteria.acceptance = []
        #expect(noCriteria.validate().contains(.noAcceptanceCriteria))
        var critical = assignment(risk: .critical)
        #expect(critical.validate().contains(.criticalNeedsGate))
        critical.gateApproved = true
        #expect(!critical.validate().contains(.criticalNeedsGate))
        var traversal = assignment(allowed: ["../outside/**"])
        #expect(traversal.validate().contains(.absoluteOrTraversingPath("../outside/**")))
        traversal.scope.allowed = ["/etc/passwd"]
        #expect(traversal.validate().contains(.absoluteOrTraversingPath("/etc/passwd")))
        var shell = assignment(); shell.verificationProfiles = ["swift test; rm -rf /"]
        #expect(shell.validate().contains(.unsafeProfileLabel("swift test; rm -rf /")))
        var both = assignment(allowed: ["calc.py"]); both.scope.forbidden = ["calc.py"]
        #expect(both.validate().contains(.forbiddenOverlapsAllowed("calc.py")))
    }

    @Test("a short objective that names its target or carries criteria is not vague")
    func vagueness() {
        #expect(EngineeringAssignment.isVague("fix the project", hasScope: false, hasAcceptance: false))
        #expect(EngineeringAssignment.isVague("make it better", hasScope: false, hasAcceptance: false))
        #expect(!EngineeringAssignment.isVague("Fix calc.py", hasScope: false, hasAcceptance: false))
        #expect(!EngineeringAssignment.isVague("fix the project", hasScope: true, hasAcceptance: true))
        #expect(!EngineeringAssignment.isVague("Repair `parse` bug", hasScope: false, hasAcceptance: false))
    }

    @Test("the worker prompt is bounded, carries scope / rules / criteria and never a repository dump; test / build / guard / dependency / delete rules are explicit unless authorised")
    func prompt() {
        var a = assignment()
        a.requirements = ["keep the public signature"]; a.constraints = ["no new dependency"]; a.conventions = ["AGENTS.md is authoritative"]
        a.scope.forbidden = ["secrets/**"]
        let text = a.promptBlock()
        #expect(text.contains("OBJECTIVE") && text.contains("MAY CHANGE ONLY: calc.py") && text.contains("NEVER TOUCH: secrets/**") && text.contains("[c1]") && text.contains("AGENTS.md"))
        #expect(text.contains("do not edit, delete, skip or weaken tests") && text.contains("add no dependency") && text.contains("delete no file") && text.contains("JARVIS verifies the real repository state itself"))
        a.scope.mayModifyTests = true; a.scope.mayDelete = true
        let relaxed = a.promptBlock()
        #expect(!relaxed.contains("do not edit, delete, skip or weaken tests") && !relaxed.contains("delete no file"))
        var big = assignment(); big.requirements = (0..<500).map { "requirement number \($0) " + String(repeating: "x", count: 200) }
        #expect(big.promptBlock(maxCharacters: 2_000).count <= 2_000)
        #expect(assignment().promptBlock().count < 1_800, "a normal assignment is small")
        var ro = assignment(); ro.scope.allowed = []
        #expect(ro.promptBlock().contains("read-only"))
    }

    @Test("the assignment maps onto the EXISTING router profile and task budget (no second routing or budget system)")
    func mapping() {
        let p = assignment().routingProfile()
        #expect(p.category == .coding && p.requiresCoding && p.requiresRepositoryModification && p.containsProjectCode && p.isDevelopment && p.complexity == .simple)
        #expect(assignment(risk: .critical).routingProfile().complexity == .critical && assignment(risk: .high).routingProfile().domainTags.contains("security"))
        var arch = assignment(); arch.requiredCapabilities = [.architecture]
        #expect(arch.routingProfile().category == .architecture && arch.routingProfile().requiresComplexReasoning)
        var ro = assignment(); ro.scope.allowed = []; ro.requiredCapabilities = [.codeReview]
        #expect(!ro.routingProfile().requiresRepositoryModification && ro.routingProfile().category == .review)
        var b = EngineeringBudget(); b.providerRequests = 9; b.verificationRuns = 4; b.wallClock = 600
        let t = b.taskBudget
        #expect(t.modelRequests == 9 && t.consecutiveVerificationFailures == 4 && t.wallClock == 600)
    }

    @Test("an assignment survives a JSON round trip (it is a persisted record)")
    func codable() throws {
        var a = assignment(); a.base = RevisionStamp(head: "abc", branch: "main", snapshotDigest: "d1"); a.domains = [.runtime, .tests]
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(EngineeringAssignment.self, from: data)
        #expect(back == a)
    }
}

@Suite("V1.0 engineering · worker report contract (claims)")
struct WorkerReportTests {
    @Test("a structured report parses into CLAIMS; prose around the JSON is tolerated; status aliases map; lists are bounded")
    func parsing() {
        let text = "Done! ```json\n{\"status\":\"completed\",\"filesChanged\":[\"calc.py\"],\"filesInspected\":[\"tests/test_calc.py\"],\"commandsRun\":[\"python3 -m unittest\",{\"command\":\"git status\",\"exitCode\":0}],\"tests\":{\"passed\":3,\"failed\":0,\"allGreen\":true},\"commit\":\"abc1234\",\"remainingWork\":[],\"apiAssumptions\":[\"dict.get\"]}\n```"
        guard case .success(let c) = WorkerReportParser.parse(text) else { Issue.record("expected claims"); return }
        #expect(c.status == .done && c.filesChanged == ["calc.py"] && c.tests?.allGreen == true && c.claimedCommit == "abc1234" && c.commandsRun.count == 2 && c.commandsRun[1].exitCode == 0 && c.apiAssumptions == ["dict.get"])
        for (raw, want) in [("ok", ClaimedStatus.done), ("failure", .failed), ("incomplete", .partial), ("blocked", .blocked)] {
            if case .success(let x) = WorkerReportParser.parse("{\"status\":\"\(raw)\"}") { #expect(x.status == want) } else { Issue.record("status \(raw)") }
        }
        let many = "{\"status\":\"done\",\"filesChanged\":[" + (0..<1000).map { "\"f\($0).py\"" }.joined(separator: ",") + "]}"
        if case .success(let x) = WorkerReportParser.parse(many) { #expect(x.filesChanged.count == WorkerReportParser.maxListItems) } else { Issue.record("bounded list") }
    }

    @Test("malformed output is a typed failure, never a guess")
    func malformed() {
        #expect(WorkerReportParser.parse("I fixed it, trust me.") == .failure(.notJSON))
        #expect(WorkerReportParser.parse("{\"filesChanged\":[\"a\"]}") == .failure(.missingStatus))
        #expect(WorkerReportParser.parse("{\"status\":\"banana\"}") == .failure(.unknownStatus("banana")))
        #expect(WorkerReportParser.parse(String(repeating: "x", count: WorkerReportParser.maxCharacters + 1)) == .failure(.tooLarge(WorkerReportParser.maxCharacters + 1)))
        #expect(WorkerReportParser.parse("{\"status\": \"done\"") == .failure(.notJSON))
    }
}

@Suite("V1.0 engineering · path classes and Git facts")
struct PathClassTests {
    @Test("paths are classified language- and project-agnostically")
    func classes() {
        func c(_ p: String) -> Set<PathClass> { PathClassifier.classes(of: p) }
        #expect(c("tests/test_calc.py").contains(.test) && c("Tests/JarvisTests/FooTests.swift").contains(.test) && c("src/foo.test.ts").contains(.test) && !c("src/latest.py").contains(.test))
        #expect(c("scripts/verify.sh").contains(.buildScript) && c(".github/workflows/ci.yml").contains(.buildScript) && c("Makefile").contains(.buildScript))
        #expect(c("scripts/guards_reliability.sh").contains(.securityGuard) && c("Sources/App/ApprovalPolicy.swift").contains(.securityGuard) && c("Sources/Net/CredentialStore.swift").contains(.securityGuard))
        #expect(c("Package.swift").contains(.dependencyManifest) && c("package.json").contains(.dependencyManifest) && c("Packages/manifest.json").contains(.dependencyManifest) && c("App.csproj").contains(.dependencyManifest))
        #expect(c("README.md").contains(.documentation) && c("docs/design.txt").contains(.documentation))
        #expect(c(".env").contains(.secretMaterial) && c("signing/dev.p12").contains(.secretMaterial) && c("App.entitlements").contains(.secretMaterial))
        #expect(c("art/hero.png").contains(.binaryAsset) && c("build/out.o").contains(.generated) && c("node_modules/x/index.js").contains(.generated))
        #expect(c("src/main.py") == [.source] && c("config.json").contains(.config))
    }

    @Test("git porcelain output becomes facts: staged, modified, untracked, renamed, conflicted")
    func porcelain() {
        let out = "M  staged.py\n M modified.py\nMM both.py\n?? new.py\nR  old.py -> renamed.py\nUU conflict.py\nA  added.py\n D deleted.py\n"
        let f = GitStatusParser.parse(out, head: "abc", branch: "main")
        #expect(f.staged == Set(["staged.py", "both.py", "renamed.py", "added.py"]))
        #expect(f.dirty.isSuperset(of: ["staged.py", "modified.py", "both.py", "renamed.py", "added.py", "deleted.py", "conflict.py"]) && f.untracked == ["new.py"] && f.conflicted == ["conflict.py"])
        #expect(!f.detached && GitFacts(head: "a", branch: "HEAD").detached && GitFacts(head: "a", branch: nil).detached)
    }
}
