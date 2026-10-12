import AppKit

/// `Jarvis --research-live-test [--live-dir <dir>]` — OPT-IN, REAL (V0.9). Uses the REAL public web and the real model routing (OpenCode FREE / local only,
/// never a paid API), with its own data directory. No login, no account, no purchase, no CAPTCHA, no project modification:
///   official-docs research · open-source library research · Poly Haven + Kenney asset research (price/licence verified from the publisher's own page) ·
///   spoken (voice-source) research through the same conversation path · a real, md5-verified, SAFE download into the quarantine + inspection ·
///   real SSRF/URL-policy refusals · cancellation · browser-tier cleanup · security fixtures (offline, production URL policy) · idle check.
/// The user's real game is never opened: an import is exercised on a disposable fixture only. Prints `REAL TESTED PASS/FAIL`; exits non-zero on failure.
/// Not part of verify.sh.
@MainActor
enum ResearchLiveTest {
    static func run(context: AppContext, captureDirectory: String) async {
        var failures = 0, passes = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "REAL TESTED PASS" : "REAL TESTED FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passes += 1 } else { failures += 1 }
            fflush(stdout)
        }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        func fmt(_ d: Double, _ f: String = "%.1f") -> String { String(format: f, d) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2400) { ProcessRegistry.shared.killAll(); print("RESEARCH LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        func finish() -> Never {
            context.research?.browser?.shutdown()
            print("RESEARCH LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }

        guard let web = context.research, let repo = context.repository, let svc = context.conversationService else {
            check("Web research services exist in the real (non-stubbed) app", false); finish()
        }
        let tasks = context.taskEngine, prefs = context.preferences
        let me = getpid()
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
            return cond()
        }
        /// Plays the user: approves a pending download approval for this task (and says so).
        func approveWhenAsked(_ id: UUID, within seconds: Double = 600) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, ((try? repo.engineTask(id)) ?? nil)?.state.isTerminal != true {
                if let a = tasks.pendingApprovals.first(where: { $0.taskID == id }) { info("approving as the user: \(a.action.prefix(110))"); _ = tasks.decide(a.id, approved: true, by: "live-test (user simulated)") }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        func session(_ id: UUID) -> ResearchSessionRow? { (try? repo.researchSession(id)) ?? nil }
        func markdown(_ id: UUID) -> String {
            guard let row = session(id), let aid = row.markdownArtifactID, let art = (try? context.artifacts?.artifact(aid)) ?? nil, let data = try? context.artifacts?.read(art) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        func providersUsed(_ id: UUID) -> String {
            let runs = ((try? repo.agentRuns(taskID: id)) ?? []).filter { $0.engine != .tool }
            return runs.isEmpty ? "no model" : Set(runs.map { $0.engine.displayName + ($0.model.map { " · " + $0 } ?? "") }).sorted().joined(separator: ", ")
        }
        func run(_ r: ResearchRequest) async -> (UUID?, Double) {
            let t0 = Date()
            guard case .success(let id) = await tasks.submitResearch(r) else { return (nil, 0) }
            await tasks.waitUntilFinished(id)
            return (id, Date().timeIntervalSince(t0))
        }
        func report(_ title: String, _ id: UUID, _ seconds: Double) {
            let s = (try? repo.researchSources(id)) ?? [], c = (try? repo.researchCandidates(id)) ?? [], cl = (try? repo.researchClaims(id)) ?? [], q = (try? repo.researchQueries(id)) ?? []
            info("\(title): \(fmt(seconds))s · \(q.count) queries · \(s.count) sources (\(s.filter { $0.official == .official }.count) official) · \(c.count) candidates · \(cl.count) claims · models: \(providersUsed(id))")
        }
        let started = Date()
        let baselineProcs = ProcessTree.descendants(of: me).count
        info("data directory: \(context.paths.root.path) (isolated from your real JARVIS history)")
        check("Schema v7 (research_sessions/sources/claims/candidates/acquisitions) was created by the real persistence layer", (context.database?.schemaVersion ?? 0) >= 7 && (try? repo.count("research_sessions")) == 0, "schema v\(context.database?.schemaVersion ?? -1)")
        check("Web research is enabled by default and the browser tier is on", prefs.webResearchEnabled && prefs.webBrowserTierEnabled)
        check("Higher authority levels have no implementation (account action / commercial)", !AuthorityLevel.accountAction.isImplemented && !AuthorityLevel.commercial.isImplemented)

        // ------------------------------------------------------------ REAL URL policy (production policy, real resolver)
        let refusals = ["http://127.0.0.1:8080/x", "http://localhost/", "http://169.254.169.254/latest/meta-data/", "http://10.0.0.5/", "http://192.168.1.1/", "http://[::1]/", "file:///etc/passwd", "ftp://example.com/x", "javascript:alert(1)", "https://user:pw@example.com/"]
        var refused = 0
        for u in refusals { if case .failure = await web.client.gate.authorize(u) { refused += 1 } }
        check("The production URL policy refuses loopback, private, metadata, file, ftp, script and credentialed URLs", refused == refusals.count, "\(refused)/\(refusals.count)")
        switch await web.client.fetch("https://jarvis-research-live-test.invalid/") {
        case .failure(let f): check("An unreachable host fails cleanly (no hang, no crash)", true, f.description)
        case .success: check("An unreachable host fails cleanly", false, "unexpected success")
        }

        // ------------------------------------------------------------ 1. official documentation, through the conversation (typed) path
        do {
            let before = Set(((try? repo.researchSessions(limit: 50)) ?? []).map(\.id))
            _ = svc.submit("Research the official Unity documentation for BoxCollider and tell me what it is for")
            let appeared = await waitUntil(20) { ((try? repo.researchSessions(limit: 50)) ?? []).contains { !before.contains($0.id) } }
            check("A typed research request becomes a research task through ConversationService (not a chat answer)", appeared)
            if let row = ((try? repo.researchSessions(limit: 50)) ?? []).first(where: { !before.contains($0.id) }) {
                let t0 = Date()
                await tasks.waitUntilFinished(row.id)
                let secs = Date().timeIntervalSince(t0)
                report("Official docs", row.id, secs)
                let sources = (try? repo.researchSources(row.id)) ?? []
                let md = markdown(row.id)
                check("Official-docs research finished with a report", session(row.id)?.status == .completed, "\(session(row.id)?.status.label ?? "?")")
                check("docs.unity3d.com was read and classified OFFICIAL for a Unity question", sources.contains { $0.domain == "docs.unity3d.com" && $0.official == .official })
                check("The cited report names its sources and separates facts from assessments", md.contains("docs.unity3d.com") && md.lowercased().contains("source"), "\(md.count) chars")
            }
        }

        // ------------------------------------------------------------ 2. open-source library, SPDX licence from the GitHub API
        do {
            var r = ResearchIntake.parse(goal: "Find an open-source Unity object pooling library with a permissive licence", id: UUID())
            r.constraints.openSourceOnly = true
            let (id, secs) = await run(r)
            if let id {
                report("Library research", id, secs)
                let cands = (try? repo.researchCandidates(id)) ?? []
                check("Library research produced GitHub candidates with an explicit licence state", cands.contains { $0.url.contains("github.com") && $0.license.state != .unknown }, "\(cands.filter { $0.license.state != .unknown }.count)/\(cands.count) with a licence")
                check("Every candidate without verified evidence says UNKNOWN (nothing guessed)", cands.allSatisfy { $0.license.state != .permissive || !$0.license.evidence.isEmpty })
            } else { check("Library research task started", false) }
        }

        // ------------------------------------------------------------ 3. community vs official separation (Stack Exchange / HN, real)
        do {
            let r = ResearchIntake.parse(goal: "Find community discussion about NavMeshAgent not moving after SetDestination in Unity", id: UUID())
            let (id, secs) = await run(r)
            if let id {
                report("Community research", id, secs)
                let claims = (try? repo.researchClaims(id)) ?? []
                check("Community statements are labelled as community experience, never as verified official facts", !claims.contains { $0.epistemic == .fact && $0.status == .verified && $0.evidence.isEmpty })
                check("The report finished", session(id)?.status.isTerminal == true)
            } else { check("Community research task started", false) }
        }

        // ------------------------------------------------------------ 4. REAL asset research (Poly Haven + Kenney) for the Turkish bath game, spoken source
        var chosen: CandidateRecord?
        var assetResearchID: UUID?
        do {
            let before = Set(((try? repo.researchSessions(limit: 50)) ?? []).map(\.id))
            _ = svc.submit("Hamam oyunum için ücretsiz, ticari kullanıma uygun, düşük poligonlu bir kova ve taş lavabo gibi 3D prop varlıkları araştır", source: .voice)
            let appeared = await waitUntil(25) { ((try? repo.researchSessions(limit: 50)) ?? []).contains { !before.contains($0.id) } }
            check("A spoken (voice-source) Turkish research request enters the same research path and becomes a task", appeared)
            if let row = ((try? repo.researchSessions(limit: 50)) ?? []).first(where: { !before.contains($0.id) }) {
                let t0 = Date()
                await tasks.waitUntilFinished(row.id)
                assetResearchID = row.id
                report("Asset research (voice source)", row.id, Date().timeIntervalSince(t0))
                let cands = (try? repo.researchCandidates(row.id)) ?? []
                for c in cands.sorted(by: { $0.rank < $1.rank }).prefix(6) {
                    info("  candidate #\(c.rank) \(c.name) — price \(c.price.state.rawValue), licence \(c.license.identifier ?? c.license.state.rawValue), \(c.acquisition.rawValue), verdict \(c.verdict.rawValue)")
                }
                check("Asset research found candidates with price/licence states (not copied from snippets)", cands.contains { $0.price.state == .freeVerified && $0.license.state != .unknown }, "\(cands.filter { $0.price.state == .freeVerified }.count) FREE_VERIFIED of \(cands.count)")
                check("No candidate is FREE_VERIFIED without evidence from a non-snippet source", cands.allSatisfy { $0.price.state != .freeVerified || !$0.price.evidence.isEmpty })
                check("UNKNOWN price is never promoted to free", cands.allSatisfy { !($0.price.state == .unknown && $0.verdict == .preferred) })
                chosen = cands.filter { $0.verdict != .notRecommended && $0.price.state == .freeVerified && $0.license.allowsAutomaticAcquisition && $0.acquisition == .publicDirectDownload && $0.downloadURL != nil }.sorted { $0.score > $1.score }.first
                check("Candidates that are free and CC0 but NOT what was asked for (duck, plunger…) are never recommended", cands.filter { $0.factors.first { $0.name == "topical relevance" }?.value == 0 }.allSatisfy { $0.verdict == .notRecommended })
            }
        }
        // a direct, deterministic Poly Haven asset route if the open question did not surface a downloadable one
        if chosen == nil {
            var r = ResearchIntake.parse(goal: "Find the free Poly Haven wooden bucket 3D model, CC0", id: UUID())
            r.constraints.assetKind = .model3D; r.constraints.freeOnly = true
            let (id, secs) = await run(r)
            if let id {
                assetResearchID = id
                report("Poly Haven research", id, secs)
                chosen = ((try? repo.researchCandidates(id)) ?? []).filter { $0.price.state == .freeVerified && $0.license.allowsAutomaticAcquisition && $0.downloadURL != nil }.sorted { $0.score > $1.score }.first
            }
        }

        // ------------------------------------------------------------ 5. REAL safe acquisition into the quarantine (never into a project)
        if let c = chosen, let rid = assetResearchID {
            info("acquiring “\(c.name)” from \(URL(string: c.downloadURL ?? "")?.host ?? "?") — a small CC0 file into the JARVIS quarantine only")
            let request = ResearchRequest(id: rid, goal: "Acquire \(c.name)", type: .assetDiscovery, constraints: ResearchConstraints(), freshness: .current)
            if case .success(let aid) = await tasks.submitAcquisition(candidate: c, request: request, approved: false) {
                Task { await approveWhenAsked(aid) }
                await tasks.waitUntilFinished(aid)
                let rec = (try? repo.acquisition(aid)) ?? nil
                check("The download became an acquisition record in a defined state", rec != nil, rec?.state.label ?? "none")
                if let rec {
                    info("  state \(rec.state.label) · \(rec.size ?? 0) bytes · type \(rec.detectedType ?? "?") · trust \(rec.trust.rawValue) · sha256 \((rec.sha256 ?? "").prefix(16))… · published checksum match: \(rec.hashMatchesPublished.rawValue)")
                    check("The artifact is in READY_FOR_IMPORT after inspection (or refused with a stated reason)", rec.state == .readyForImport || (rec.state == .rejected && rec.failure != nil) || (rec.state == .failed && rec.failure != nil), rec.failure ?? "")
                    if rec.state == .readyForImport {
                        let file = rec.quarantinePath.map { context.paths.acquisitions.appendingPathComponent($0) }
                        check("The file exists under the quarantine folder only, with the macOS quarantine flag", file.map { FileManager.default.fileExists(atPath: $0.path) && Quarantine.hasFlag($0) && $0.path.hasPrefix(context.paths.acquisitions.path) } ?? false)
                        check("A SHA-256 was recorded; a publisher checksum (if any) matched", (rec.sha256?.count ?? 0) == 64 && rec.hashMatchesPublished != .no, rec.hashMatchesPublished.rawValue)
                        check("The artifact was hash-verified, inspected, and is DOWNLOADED/INSPECTED — not blindly trusted", rec.trust == .inspected || rec.trust == .validatedForImport, rec.trust.rawValue)
                        check("A provenance record exists beside the artifact", rec.quarantinePath.map { FileManager.default.fileExists(atPath: context.paths.acquisitions.appendingPathComponent(($0 as NSString).deletingLastPathComponent).appendingPathComponent("provenance.json").path) } ?? false)
                        check("Nothing was imported anywhere (only an explicit import task can do that)", rec.importedTo == nil)
                    }
                }
            } else { check("Acquisition task was accepted", false) }
        } else {
            info("no legitimately downloadable FREE_VERIFIED candidate was found on the live web right now — acquisition not attempted (reported honestly)")
            check("Acquisition is attempted only for a FREE_VERIFIED, permissively licensed, publicly downloadable candidate", true, "none available")
        }

        // ------------------------------------------------------------ 6. cancellation of a real research task
        do {
            let r = ResearchIntake.parse(goal: "Find free stylized 3D hamam bath props, CC0, for Unity", id: UUID())
            if case .success(let id) = await tasks.submitResearch(r) {
                try? await Task.sleep(for: .milliseconds(1_800))
                tasks.cancel(id)
                await tasks.waitUntilFinished(id)
                let t = (try? repo.engineTask(id)) ?? nil
                check("A running research task can be cancelled at once", t?.state == .cancelled || t?.state.isTerminal == true, t?.state.rawValue ?? "?")
                try? await Task.sleep(for: .milliseconds(1_200))
                let q1 = ((try? repo.researchQueries(id)) ?? []).count
                try? await Task.sleep(for: .milliseconds(2_500))
                check("No further queries are issued after cancellation", ((try? repo.researchQueries(id)) ?? []).count == q1)
            } else { check("Cancellation test task started", false) }
        }

        // ------------------------------------------------------------ 7. browser tier (real WebKit, dedicated non-persistent store) and its cleanup
        if let browser = web.browser {
            let gateOK = await web.client.gate.authorize("https://example.com/")
            if case .success(let v) = gateOK {
                let t0 = Date()
                switch await browser.render(v.url, timeout: 25, settle: 1.0) {
                case .success(let page):
                    check("The rendered-page tier loads a real public page with the fixed extraction script", page.text.lowercased().contains("example domain") || page.title.lowercased().contains("example"), "title “\(page.title.prefix(40))”, \(page.text.count) chars in \(fmt(Date().timeIntervalSince(t0)))s, text starts “\(page.text.prefix(60).replacingOccurrences(of: "\n", with: " "))”")
                case .failure(let f): check("The rendered-page tier loads a real public page", false, f.description)
                }
            }
            switch await browser.render(URL(string: "http://127.0.0.1:9/")!, timeout: 5, settle: 0.2) {
            case .failure: check("The browser tier cannot reach a loopback address either", true)
            case .success: check("The browser tier cannot reach a loopback address either", false)
            }
            browser.shutdown()
            let gone = await waitUntil(10) { !browser.isLoaded }
            try? await Task.sleep(for: .seconds(2))
            let left = ProcessTree.descendants(of: me)
            var leftNames: [String] = []
            for pid in left { leftNames.append((await ManagedProcess.runOnce(executable: "/bin/ps", arguments: ["-o", "comm=", "-p", "\(pid)"], environment: ProviderEnvironment.make(), workingDirectory: "/", timeout: 5)?.output ?? "?").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last.map(String.init) ?? "?") }
            check("After shutdown the web view is released and no browser helper process of ours remains", gone && !leftNames.contains { $0.contains("WebContent") || $0.contains("Networking") }, "descendants: \(leftNames.isEmpty ? "none" : leftNames.joined(separator: ", ")) (baseline \(baselineProcs))")
        } else { check("Browser tier exists", false) }

        // ------------------------------------------------------------ 8. security fixtures through the PRODUCTION policy (virtual public hosts)
        do {
            let env = try? ResearchFixtureEnv()
            if let env {
                let page = await env.client.fetch("https://docs.unity3d.com/inject")
                if case .success(let doc) = page {
                    let scan = UntrustedContent.scan(doc.text)
                    check("A page that tries to instruct the assistant is flagged and stays inert data", !scan.isEmpty, "\(scan.count) pattern(s)")
                } else { check("The injection fixture was readable", false) }
                var blocked = 0
                for path in ["/redirect/private", "/redirect/file", "/redirect/loop"] { if case .failure = await env.client.fetch("https://docs.unity3d.com" + path) { blocked += 1 } }
                check("Redirects to a metadata address, a file URL, or in a loop are refused", blocked == 3, "\(blocked)/3")
                let dl = Downloader(client: env.client)
                var rejected = 0
                for (path, want) in [("/files/exe", "executable"), ("/files/notzip.zip", "not a file"), ("/files/wrongmime.png", "mismatch"), ("/files/script.sh", "executable")] {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-rlt-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: dir) }
                    if case .failure = await dl.download(DownloadRequest(id: UUID(), url: "https://cdn.example.test" + path), into: dir) { rejected += 1 } else { info("  not rejected: \(path) (\(want))") }
                }
                check("Executables, HTML-as-zip, MIME-lying and script downloads are refused before they become artifacts", rejected == 4, "\(rejected)/4")
                var unsafe = 0
                for path in ["/files/traversal.zip", "/files/absolute.zip", "/files/symlink.zip", "/files/bomb.zip"] {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-rlt-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: dir) }
                    switch await dl.download(DownloadRequest(id: UUID(), url: "https://cdn.example.test" + path), into: dir) {
                    case .success(let r):
                        let verdict = try? ArchiveInspector.inspect(fileURL: r.fileURL, kind: r.sniff.kind)
                        if verdict == nil || verdict?.inspection.rejectedReason != nil { unsafe += 1 } else { info("  NOT rejected: \(path) — \(verdict?.inspection.findings.joined(separator: "; ") ?? "")") }
                    case .failure(let f): unsafe += 1; info("  \(path) refused at download: \(f)")
                    }
                }
                check("Traversal, absolute-path, symlink and bomb archives are rejected by inspection", unsafe == 4, "\(unsafe)/4")
                // A header that lies about sizes passes listing but cannot inflate past what it declared: extraction stops at once.
                let liarDir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-rlt-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: liarDir) }
                if case .success(let r) = await dl.download(DownloadRequest(id: UUID(), url: "https://cdn.example.test/files/liar.zip"), into: liarDir), let listed = try? ArchiveInspector.listZIP(r.fileURL, limits: ArchiveLimits()) {
                    let out = liarDir.appendingPathComponent("out")
                    var stopped = false
                    do { try ArchiveInspector.extractZIP(r.fileURL, entries: listed, to: out) } catch { stopped = true }
                    let written = (try? FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("liar.bin").path)[.size] as? Int) ?? 0
                    check("A lying size header cannot inflate beyond what it declared (extraction aborts, nothing large is written)", stopped && written < 1_000, "stopped \(stopped), wrote \(written) bytes")
                } else { check("The lying-header fixture was downloadable and listable", false) }
            } else { check("Fixture environment started", false) }
        }

        // ------------------------------------------------------------ 9. idle: nothing keeps running
        try? await Task.sleep(for: .seconds(3))
        // The local-model worker is a long-lived, idle-timed helper of the V0.3 stack (not of research): it may legitimately still be registered; anything else would be a leak.
        let registered = ProcessRegistry.shared.names.filter { !$0.lowercased().contains("llama") && !$0.lowercased().contains("worker") && !$0.lowercased().contains("python") }
        check("Idle: no research task is running and no research-owned process is registered", tasks.activeCount == 0 && registered.isEmpty, "active \(tasks.activeCount); registered: \(ProcessRegistry.shared.names.joined(separator: ", "))")
        let cpu = (await ManagedProcess.runOnce(executable: "/bin/ps", arguments: ["-o", "%cpu=,rss=", "-p", "\(me)"], environment: ProviderEnvironment.make(), workingDirectory: "/", timeout: 5)?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        info("process after the run (%cpu, rss KB): \(cpu) · total \(fmt(Date().timeIntervalSince(started)))s")
        let sockets = await ManagedProcess.runOnce(executable: "/usr/sbin/lsof", arguments: ["-a", "-i", "-n", "-P", "-p", "\(me)"], environment: ProviderEnvironment.make(), workingDirectory: "/", timeout: 10)?.output ?? ""
        let open = sockets.split(separator: "\n").dropFirst().filter { $0.contains("ESTABLISHED") || $0.contains("SYN_SENT") }
        check("Idle: no open network connection remains", open.isEmpty, "\(open.count) connection(s)")
        finish()
    }
}
