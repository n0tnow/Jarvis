import Foundation

/// Per-task state of a web task (research, acquisition) or of an asset-import task. In memory only; the durable facts are the research tables,
/// the acquisition row, the step evidence and the report artifact.
@MainActor
final class ResearchRuntime {
    var request: ResearchRequest
    var pipeline: ResearchPipeline?
    var report: ResearchReport?
    var markdown: String?
    var candidate: CandidateRecord?               // acquisition: the candidate to fetch
    var acquisition: AcquisitionRecord?           // acquisition: the record being driven
    var approvedDownload = false                  // the user pre-approved the exact reasons shown (submit-time approval)
    var importSource: AcquisitionRecord?          // import task: the quarantined artifact
    var includeCode = false                       // import task: the user explicitly approved importing scripts / native code
    var queriesRun = 0, sourcesOpened = 0, candidatesFound = 0
    init(request: ResearchRequest) { self.request = request }
}

extension TaskEngine {
    // MARK: Submission (all three are ordinary V0.4 tasks)

    @discardableResult
    func submitResearch(_ request: ResearchRequest, preference: ProviderPreference? = nil, inputChannel: InputSource = .typed, origin: TaskOrigin = .userTask, scope: TaskScope? = nil,
                        originTaskID: UUID? = nil, originOpportunityID: UUID? = nil, autonomyDepth: Int = 0) async -> Result<UUID, TaskSubmitError> {
        guard let web, webAllowed() else { return .failure(.workspace(web == nil ? "Web research is not available in this build." : "Web research is turned off in Settings → Web research.")) }
        let title = "Research · " + String(request.goal.prefix(60))
        let runtime = ResearchRuntime(request: request)
        return await submit(goal: request.goal, kind: .research, workspacePath: web.paths.researchWorkspace.path, constraints: request.constraints.summary, preference: preference, title: title, id: request.id,
                            origin: origin, originTaskID: originTaskID, originOpportunityID: originOpportunityID, autonomyDepth: autonomyDepth, scope: scope, inputChannel: inputChannel, prepare: { ctx in ctx.research = runtime })
    }

    /// An acquisition is its own task (so it has its own approval, progress, cancellation and report); its id equals the acquisition id.
    @discardableResult
    func submitAcquisition(candidate: CandidateRecord, request: ResearchRequest?, approved: Bool = false, preference: ProviderPreference? = nil, inputChannel: InputSource = .typed) async -> Result<UUID, TaskSubmitError> {
        guard let web, webAllowed() else { return .failure(.workspace(web == nil ? "Acquisition is not available in this build." : "Web research is turned off in Settings → Web research.")) }
        let id = UUID()
        let req = request ?? ResearchRequest(id: id, goal: "Acquire \(candidate.name)", type: .assetDiscovery, constraints: ResearchConstraints(), freshness: .current)
        let runtime = ResearchRuntime(request: req)
        runtime.candidate = candidate; runtime.approvedDownload = approved
        var rec = web.acquisition.newRecord(for: candidate, researchID: req.id, taskID: id, licenseSourceURL: nil, id: id)
        rec.expectedSHA256 = candidate.expectedSHA256
        web.persistence?.save(rec)
        runtime.acquisition = rec
        return await submit(goal: "Download “\(candidate.name)” into the quarantine", kind: .acquisition, workspacePath: web.paths.researchWorkspace.path, constraints: ["no import", "no account action", "no purchase"], preference: preference,
                            title: "Acquire · " + String(candidate.name.prefix(60)), id: id, inputChannel: inputChannel, prepare: { ctx in ctx.research = runtime })
    }

    /// Import a quarantined, inspected artifact into a project: a V0.4 DEVELOPMENT task (workspace guard, approval, leases, report) — never a research side effect.
    @discardableResult
    func submitImport(_ acquisition: AcquisitionRecord, projectRoot: String, includeCode: Bool = false, preference: ProviderPreference? = nil) async -> Result<UUID, TaskSubmitError> {
        guard web != nil, webAllowed() else { return .failure(.workspace("Import is not available (web research is off or missing).")) }
        guard acquisition.state == .readyForImport else { return .failure(.workspace("The artifact is not ready for import (\(acquisition.state.label)).")) }
        let unityProject = UnityProjectDetector.isUnityProject(root: projectRoot)
        var caps = CapabilitySet.for(.development, unityProject: unityProject).granted
        caps.insert(.importIntoProject)
        let req = ResearchRequest(id: UUID(), goal: "Import \(acquisition.name)", type: .assetDiscovery, constraints: ResearchConstraints(), freshness: .timeless)
        let runtime = ResearchRuntime(request: req)
        runtime.importSource = acquisition; runtime.includeCode = includeCode
        return await submit(goal: "Import “\(acquisition.name)” (quarantined, inspected) into the project", kind: .development, workspacePath: projectRoot, constraints: ["import only the inspected quarantine copy", includeCode ? "scripts approved by the user" : "no scripts or native code"],
                            preference: preference, title: "Import · " + String(acquisition.name.prefix(60)), capabilities: CapabilitySet(granted: caps), prepare: { ctx in ctx.research = runtime })
    }

    // MARK: Runtime / pipeline plumbing

    func researchRuntime(_ ctx: TaskContext) -> ResearchRuntime? {
        if let rt = ctx.research { return rt }
        guard let repository else { return nil }
        // restart: rebuild from the durable rows
        if ctx.record.kind == .research, let row = (try? repository.researchSession(ctx.record.id)) ?? nil {
            let req = ResearchRequest(id: row.id, goal: row.goal, type: row.type, constraints: row.constraints, freshness: row.freshness, deep: row.deep, createdAt: row.createdAt, project: nil)
            ctx.research = ResearchRuntime(request: req)
        } else if ctx.record.kind == .research {
            ctx.research = ResearchRuntime(request: ResearchIntake.parse(goal: ctx.record.goal, id: ctx.record.id))
        } else if ctx.record.kind == .acquisition, let rec = (try? repository.acquisition(ctx.record.id)) ?? nil {
            let cand = rec.candidateID.flatMap { cid in (try? repository.researchCandidates(rec.researchID ?? cid))?.first { $0.id == cid } }
            let rt = ResearchRuntime(request: ResearchRequest(id: rec.researchID ?? rec.id, goal: ctx.record.goal, type: .assetDiscovery, constraints: ResearchConstraints(), freshness: .current))
            rt.acquisition = rec; rt.candidate = cand
            ctx.research = rt
        }
        return ctx.research
    }

    func planWebTask(_ ctx: TaskContext) -> Bool {
        guard web != nil else { ctx.hardFailure = (.providerUnavailable, "Web research is not available."); return false }
        guard let rt = researchRuntime(ctx) else { ctx.hardFailure = (.toolFailed, "The research request could not be restored."); return false }
        let plan: TaskPlan
        if let src = rt.importSource { plan = ResearchPlanner.importPlan(name: src.name, unity: ctx.unityProject) }
        else if ctx.record.kind == .acquisition { plan = ResearchPlanner.acquisitionPlan(name: rt.candidate?.name ?? rt.acquisition?.name ?? ctx.record.title) }
        else { plan = ResearchPlanner.plan(for: rt.request) }
        installPlan(ctx, plan)
        return true
    }

    private func pipeline(_ ctx: TaskContext) async -> ResearchPipeline? {
        guard let web, let rt = researchRuntime(ctx) else { return nil }
        if let p = rt.pipeline { return p }
        let p = ResearchPipeline(request: rt.request, client: web.client, providers: web.providers, rendered: browserTierAllowed() ? web.rendered : nil, persist: web.persistence, model: researchModelCall(ctx),
                                 events: { [weak self, weak ctx] e in guard let ctx else { return }; Task { @MainActor in self?.researchEvent(ctx, e) } })
        if let repository, (try? repository.researchSession(rt.request.id)) != nil {
            let id = rt.request.id
            await p.restore(queries: (try? repository.researchQueries(id)) ?? [], sources: (try? repository.researchSources(id)) ?? [], claims: (try? repository.researchClaims(id)) ?? [], candidates: (try? repository.researchCandidates(id)) ?? [])
        }
        rt.pipeline = p
        return p
    }

    // MARK: Model calls inside research steps (routed, sanitized, audited like every other agent run)

    private func researchModelCall(_ ctx: TaskContext) -> ModelCall {
        return { [weak self, weak ctx] purpose, prompt, validate in
            guard let self, let ctx else { return nil }
            return await self.runResearchModel(ctx, purpose: purpose, prompt: prompt, validate: validate)
        }
    }

    private func runResearchModel(_ ctx: TaskContext, purpose: ModelPurpose, prompt: String, validate: @escaping @Sendable (String) -> Bool) async -> ModelAnswer? {
        if ctx.cancelRequested || Task.isCancelled { return nil }
        var profile = TaskClassifier.profile(for: ctx.record.goal)
        switch purpose { case .queryPlanning: profile.category = .classification; case .extraction: profile.category = .extraction; case .styleAssessment: profile.category = .summarization }
        profile.requiresCoding = false; profile.containsProjectCode = false; profile.requiresRepositoryModification = false
        profile.wantsStructuredOutput = true
        profile.complexity = purpose == .extraction ? .moderate : .simple
        profile.privacy = ctx.record.privacy
        profile.estimatedContextTokens = max(profile.estimatedContextTokens, prompt.count / 4)
        let job = AgentJob(type: "ResearchAgent", title: "Research · \(purpose.rawValue)", prompt: prompt, profile: profile, taskID: ctx.record.id,
                           validator: { text in validate(text) ? BenchmarkSuite.Verdict(passed: true, detail: "") : BenchmarkSuite.Verdict(passed: false, detail: "reply with the requested JSON object only") },
                           timeout: 240)
        mutate(ctx) { $0.activity = purpose == .extraction ? "Extracting facts (model)" : "Asking a model" }
        let result = await runJob(ctx, job)
        if case .completed(let text, _, let cand, _) = result { return ModelAnswer(text: text, provider: cand.engine.displayName, model: cand.model) }
        return nil
    }

    // MARK: Events → activity (bounded; never page bodies)

    func researchEvent(_ ctx: TaskContext, _ e: ResearchEvent) {
        guard let rt = ctx.research, !ctx.record.state.isTerminal else { return }
        switch e {
        case .queryStarted: rt.queriesRun += 1; mutate(ctx) { $0.activity = "Searching · query \(rt.queriesRun)" }
        case .sourceOpened: rt.sourcesOpened += 1; mutate(ctx) { $0.activity = "Reading · \(rt.sourcesOpened) source\(rt.sourcesOpened == 1 ? "" : "s")" }
        case .candidateAdded: rt.candidatesFound += 1; mutate(ctx) { $0.activity = "Comparing · \(rt.candidatesFound) candidate\(rt.candidatesFound == 1 ? "" : "s")" }; note(e.summary, .info, taskID: ctx.record.id)
        case .stage(let s, _): if !s.isTerminal { mutate(ctx) { $0.activity = s == .reading ? "Reading · \(rt.sourcesOpened) source\(rt.sourcesOpened == 1 ? "" : "s")" : "\(s.label)…" } }
        case .searchFailed, .sourceRejected, .browserEscalation, .injectionDetected: note(e.summary, .warning, taskID: ctx.record.id)
        case .priceVerified, .licenseVerified, .reportCompleted, .started: note(e.summary, .info, taskID: ctx.record.id)
        case .claimVerified, .candidateRejected, .modelCall, .searchResults: break
        }
    }

    // MARK: Step runners

    private func mapFailure(_ f: ResearchFailure) -> StepOutcome {
        switch f {
        case .cancelled: return .cancelled
        case .offline: return .failed(.networkUnavailable, "There is no network connection.")
        case .blockedByURLPolicy(let w), .ssrfPostCheck(let w): return .failed(.blockedByNetworkPolicy, w)
        case .captcha, .loginWall: return .failed(.interactionRequired, f.description)
        case .noResults: return .failed(.noSources, "Nothing readable was found for this question.")
        case .budgetExhausted(let w): return .failed(.noSources, "The research budget ended (\(w)) before enough was found.")
        default: return .failed(.toolFailed, f.description)
        }
    }

    private func pass(_ ctx: TaskContext, _ key: String, _ evidence: String) -> StepOutcome {
        verifying(ctx, key)
        setStep(ctx, key, to: .passed, evidence: evidence, result: evidence)
        return .passed
    }

    func runResearchSearch(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let p = await pipeline(ctx) else { return .failed(.providerUnavailable, "Web research is not available.") }
        switch await p.search() {
        case .success(let n):
            let snap = await p.snapshot()
            let providers = Set(snap.queries.filter { $0.failure == nil }.map(\.provider))
            return pass(ctx, key, "\(n) unique result(s) from \(snap.queries.count) quer\(snap.queries.count == 1 ? "y" : "ies") via \(providers.sorted().joined(separator: ", "))" + (snap.warnings.isEmpty ? "" : " · warnings: " + snap.warnings.joined(separator: "; ")))
        case .failure(let f): if !ctx.terminating { await p.markEnded(f) }; return mapFailure(f)
        }
    }

    func runResearchRead(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let p = await pipeline(ctx) else { return .failed(.providerUnavailable, "Web research is not available.") }
        switch await p.read() {
        case .success(let n):
            let snap = await p.snapshot()
            let rendered = snap.sources.filter { $0.method == .renderedBrowser }.count
            return pass(ctx, key, "\(n) source(s) read\(rendered > 0 ? " (\(rendered) with the browser tier)" : "") · \(snap.meter.bytes / 1024) KB · \(snap.injectionNotes.isEmpty ? "no page tried to instruct the assistant" : "\(snap.injectionNotes.count) page(s) tried to instruct the assistant — ignored")")
        case .failure(let f): if !ctx.terminating { await p.markEnded(f) }; return mapFailure(f)
        }
    }

    func runResearchExtract(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let p = await pipeline(ctx) else { return .failed(.providerUnavailable, "Web research is not available.") }
        await p.rehydrateDocuments()
        let n = await p.extract()
        if ctx.cancelRequested || Task.isCancelled { return .cancelled }
        let snap = await p.snapshot()
        return pass(ctx, key, "\(n) candidate(s), \(snap.claims.count) claim(s) recorded" + (snap.modelNotes.isEmpty ? " · no model was used" : " · " + snap.modelNotes.joined(separator: "; ")))
    }

    func runResearchVerify(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let p = await pipeline(ctx) else { return .failed(.providerUnavailable, "Web research is not available.") }
        await p.verify()
        if ctx.cancelRequested || Task.isCancelled { return .cancelled }
        let snap = await p.snapshot()
        let free = snap.candidates.filter { $0.price.state == .freeVerified }.count
        return pass(ctx, key, "\(snap.candidates.count) candidate(s) verified now: \(free) FREE_VERIFIED, \(snap.candidates.filter { $0.price.state == .unknown }.count) price UNKNOWN, \(snap.candidates.filter { $0.license.state == .unknown }.count) licence UNKNOWN")
    }

    func runResearchReport(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let p = await pipeline(ctx), let rt = ctx.research else { return .failed(.providerUnavailable, "Web research is not available.") }
        if ctx.cancelRequested || Task.isCancelled { return .cancelled }
        await p.compare()
        let (report, md) = await p.buildReport()
        rt.report = report; rt.markdown = md
        // Every verified FACT must carry its evidence (the report is not "a model read pages and answered").
        let unsupported = report.facts.filter { $0.status == .verified && $0.sourceIDs.isEmpty }
        if !unsupported.isEmpty { return .failed(.validationFailed, "\(unsupported.count) verified fact(s) have no source: " + unsupported.prefix(2).map(\.text).joined(separator: "; ")) }
        researchSummaries[ctx.record.id] = Self.summaryLine(for: report)
        mutate(ctx) { $0.summary = Self.summaryLine(for: report) }
        return pass(ctx, key, "Report ready: \(report.sourceCount) source(s), \(report.facts.count) fact(s), \(report.candidates.count) candidate(s), \(report.contradictions.count) contradiction(s), \(report.uncertainties.count) uncertaint\(report.uncertainties.count == 1 ? "y" : "ies")")
    }

    static func summaryLine(for r: ResearchReport) -> String {
        var s = "Research finished (\(r.sourceCount) sources). " + r.recommendation
        if !r.uncertainties.isEmpty { s += " \(r.uncertainties.count) thing\(r.uncertainties.count == 1 ? "" : "s") remain UNKNOWN." }
        return String(s.prefix(700)) + " The cited report is on the Research screen."
    }

    /// The conversation message for a finished web task (nil → the normal task summary).
    func researchSummary(for v: TaskView) -> String? {
        guard v.task.kind.isWebTask else { return nil }
        if v.task.state == .completed { return researchSummaries[v.id] ?? v.task.summary }
        return nil
    }

    // MARK: Acquisition

    func runAcquire(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let web, let rt = researchRuntime(ctx), let step = ctx.step(key), let original = rt.candidate else { return .failed(.providerUnavailable, "Acquisition is not available.") }
        // 1. Verify AGAIN, now: the price/licence that justified this task may be hours old.
        mutate(ctx) { $0.activity = "Re-verifying price and licence" }
        let p = ResearchPipeline(request: rt.request, client: web.client, providers: [], rendered: browserTierAllowed() ? web.rendered : nil, persist: web.persistence, model: nil,
                                 events: { [weak self, weak ctx] e in guard let ctx else { return }; Task { @MainActor in self?.researchEvent(ctx, e) } })
        let fresh = await p.reverify(original)
        rt.candidate = fresh
        if ctx.cancelRequested || Task.isCancelled { return .cancelled }
        var record = web.acquisition.newRecord(for: fresh, researchID: rt.request.id, taskID: ctx.record.id, licenseSourceURL: fresh.url, id: ctx.record.id)
        record.expectedSHA256 = fresh.expectedSHA256
        // 2. Decide with the explicit policy; ask the user with the exact consequences when it is not clear-cut.
        let decision = AcquisitionPolicy.evaluate(fresh, requireHTTPS: web.acquisition.limits.requireHTTPS)
        var approved = false
        switch decision {
        case .rejected(let why):
            web.acquisition.move(&record, to: .verifying); web.acquisition.move(&record, to: .rejected, failure: why.joined(separator: "; ")); rt.acquisition = record
            return .failed(.acquisitionRefused, why.joined(separator: "; "))
        case .approvalRequired(let why):
            if rt.approvedDownload { approved = true }
            else {
                let host = URL(string: fresh.downloadURL ?? "")?.host ?? "the publisher"
                let reasons = why.filter { $0.contains("review") || $0.contains("not FREE_VERIFIED") || $0.contains("24 h") || $0.contains("trusted") || $0.contains("large") }
                let ok = await requestApproval(ctx, step, action: "Download “\(fresh.name.prefix(60))” from \(host) into the JARVIS quarantine",
                                               reason: "Why asking: " + (reasons.isEmpty ? why : reasons).joined(separator: "; ") + ". No payment is made, no account action is performed, nothing is imported into any project and nothing is run.", risk: .medium)
                if ctx.cancelRequested || Task.isCancelled { return .cancelled }
                guard ok else {
                    web.acquisition.move(&record, to: .verifying); web.acquisition.move(&record, to: .approvalRequired, failure: "not approved"); web.acquisition.move(&record, to: .rejected, failure: "the download was not approved"); rt.acquisition = record
                    return .failed(.approvalDenied, "The download was not approved.")
                }
                approved = true
            }
        case .eligible: break
        }
        // 3. Download → quarantine → inspect (the service owns the state machine and persistence).
        let result = await web.acquisition.acquire(fresh, researchID: rt.request.id, taskID: ctx.record.id, approved: approved, expectedMD5: fresh.expectedMD5, expectedSHA256: fresh.expectedSHA256, licenseSourceURL: fresh.url, record: record) { [weak self, weak ctx] r in
            guard let ctx else { return }
            Task { @MainActor in
                let got = Double(r.bytesDownloaded ?? 0) / 1_048_576, total = r.bytesExpected.map { Double($0) / 1_048_576 }
                self?.mutate(ctx) { $0.activity = total.map { String(format: "Downloading · %.1f / %.1f MB", got, $0) } ?? String(format: "Downloading · %.1f MB", got) }
            }
        }
        rt.acquisition = result
        if ctx.terminating { return .cancelled }
        if ctx.cancelRequested || Task.isCancelled || result.state == .cancelled { return .cancelled }
        switch result.state {
        case .readyForImport:
            let insp = result.inspection
            let ev = "\(result.name): \(result.size.map { "\($0 / 1024) KB" } ?? "?") · SHA-256 \(result.sha256?.prefix(16) ?? "?")… · type \(result.detectedType ?? "?") · from \(result.finalHost ?? "?") · \(result.trust.rawValue)" +
                (result.hashMatchesPublished == .yes ? " · matches the published checksum" : result.hashMatchesPublished == .no ? " · CHECKSUM MISMATCH" : " · no published checksum to compare") +
                (insp.map { " · \($0.entryCount) entr\($0.entryCount == 1 ? "y" : "ies")" + ($0.findings.isEmpty ? "" : " · " + $0.findings.joined(separator: "; ")) } ?? "")
            let message = "Downloaded “\(result.name)” into the quarantine (\(result.trust.rawValue), SHA-256 \(result.sha256?.prefix(12) ?? "?")…). Nothing was imported or run. " + (insp?.findings.isEmpty == false ? "Inspection notes: " + insp!.findings.prefix(2).joined(separator: "; ") + "." : "")
            researchSummaries[ctx.record.id] = message
            mutate(ctx) { $0.summary = message }
            return pass(ctx, key, ev)
        case .rejected: return .failed(.acquisitionRefused, result.failure ?? "the artifact was rejected")
        case .approvalRequired: return .failed(.approvalDenied, result.failure ?? "approval is required")
        default: return .failed(.downloadFailed, result.failure ?? "the download failed")
        }
    }

    // MARK: Import (writes into a project: ordinary V0.4 tool step with its own approval)

    func runImportAsset(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let web, let rt = researchRuntime(ctx), let step = ctx.step(key), let src = rt.importSource else { return .failed(.providerUnavailable, "Import is not available.") }
        guard ctx.record.capabilities.allows(.importIntoProject) else { return .failed(.capabilityDenied, "This task does not grant importing into a project.") }
        // The quarantine copy must still be exactly what was inspected.
        guard web.acquisition.verifyStored(src) else { return .failed(.securityBlocked, "The quarantined file no longer matches its recorded SHA-256 — it will not be imported.") }
        mutate(ctx) { $0.activity = "Preparing the import (quarantine → inspection copy)" }
        let service = web.acquisition
        let extracted: (root: URL, files: [String])
        do { extracted = try await Task.detached { try service.extractForImport(src) }.value } catch { return .failed(.securityBlocked, "The artifact could not be unpacked safely: \(error)") }
        if ctx.cancelRequested || Task.isCancelled { return .cancelled }
        let plan: ImportPlan
        do { plan = try AssetImporter.prepare(record: src, extractedRoot: extracted.root, files: extracted.files, workspace: ctx.workspace, unityProject: ctx.unityProject, includeCode: rt.includeCode) }
        catch { return .failed(.toolFailed, "\(error)") }
        // Approval: exactly what will be written, what is left out, where the files came from and under which licence.
        let flagged = plan.flagged.isEmpty ? "" : " Includes code: \(plan.flagged.prefix(3).joined(separator: ", "))."
        let action = "Import “\(src.name.prefix(50))” into \(ctx.workspace.root.split(separator: "/").last.map(String.init) ?? "the project") → \(plan.destination): \(plan.files.count) file(s), \(plan.totalBytes / 1024) KB"
        let reason = "Source: \(src.sourceURL) · licence \(src.licenseID ?? "UNKNOWN") · price when acquired \(src.priceState?.rawValue ?? "UNKNOWN") · SHA-256 \(src.sha256?.prefix(12) ?? "?")….\(flagged) \(plan.skipped.count) file(s) are left out (\(Set(plan.skipped.map(\.reason)).prefix(3).joined(separator: "; "))). Nothing is executed. A provenance file is written next to the files."
        let ok = await requestApproval(ctx, step, action: action, reason: reason, risk: .high)
        if ctx.cancelRequested || Task.isCancelled { return .cancelled }
        guard ok else { return .failed(.approvalDenied, "The import was not approved.") }
        mutate(ctx) { $0.activity = "Importing \(plan.files.count) file(s)" }
        let ws = ctx.workspace, taskID = ctx.record.id, flag = CancelFlag()
        let report: ImportReport
        do {
            report = try await withTaskCancellationHandler {
                try await Task.detached { try AssetImporter.apply(plan, record: src, taskID: taskID, workspace: ws, shouldContinue: { !flag.cancelled }) }.value
            } onCancel: { flag.cancel() }
        } catch is CancellationError { return .cancelled }
        catch { return .failed(.toolFailed, "\(error)") }
        // Audit: the created files (bounded) and the provenance file are recorded like any other change.
        for f in plan.files.prefix(120) {
            let c = TaskFileChange(path: plan.destination + "/" + f.relative, changeType: "created", beforeHash: nil, afterHash: f.sha256, stepKey: key, preexistingUserChange: false)
            ctx.changes.append(c); try? repository?.insertTaskFileChange(c, taskID: ctx.record.id, agentRunID: nil)
        }
        var updated = src; updated.importedTo = plan.destination; updated.importTaskID = ctx.record.id; updated.updatedAt = Date()
        web.persistence?.save(updated)
        let ev = "Imported \(report.copied) file(s) (\(report.bytes / 1024) KB) into \(report.destination); every copy hash-verified; provenance \(report.provenancePath); \(report.skipped) file(s) left out"
        ctx.evidence.append(ev)
        return pass(ctx, key, ev)
    }
}

/// Lets a detached copy loop notice that the task was stopped.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
