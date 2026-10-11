import Testing
import Foundation
@testable import Jarvis

private func code(_ sub: String) -> [(path: String, text: String)] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(sub)
    var out: [(String, String)] = []
    for u in (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] where u.pathExtension == "swift" {
        let text = FileManager.default.contents(atPath: u.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        out.append((u.path, text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")))
    }
    return out
}

@Suite("V0.5 structural guarantees (source-level, next to verify.sh)")
struct ProactiveGuardTests {
    @Test func theDecisionLayerNeverWritesProjectFilesOrRunsProcesses() {
        let files = code("Sources/Jarvis/Proactive")
        #expect(files.count >= 7)
        for (path, text) in files {
            for bad in [".write(to:", ".write(contentsOf", "createFile(", "removeItem(", "moveItem(", "copyItem(", "setAttributes(", "Process()", "ManagedProcess", "CommandRunner", "ProjectTools(workspace: ws, capabilities: .development", ".apply(", ".delete("] {
                #expect(!text.contains(bad), "\(path) contains \(bad)")
            }
        }
    }

    @Test func projectToolsInTheDecisionLayerAreReadOnly() {
        for (path, text) in code("Sources/Jarvis/Proactive") where text.contains("ProjectTools(") {
            #expect(text.contains("capabilities: .readOnly") && !text.contains("capabilities: .development") && !text.contains("writeProject)"), "\(path) must only read")
        }
    }

    @Test func onlyTheProposalServiceDecidesProposalsAndNothingParsesTextIntoDecisions() {
        for (path, text) in code("Sources/Jarvis") where !path.hasSuffix("ProposalService.swift") {
            // writes of decision states (approved/denied) on proposals or approvals happen only in ProposalService (and the V0.4 step approvals inside TaskEngine)
            if path.contains("/Proactive/") || path.contains("/Persistence/OpportunityRepository") {
                #expect(!text.contains("status = .approved") && !text.contains("state = .approved") && !text.contains(".approve("), "\(path) must not decide approvals")
            }
        }
        let service = code("Sources/Jarvis/Proactive").first { $0.path.hasSuffix("ProposalService.swift") }?.text ?? ""
        #expect(service.contains("enum DecisionSource") && service.contains("func approve(_ proposalID: UUID, source: DecisionSource)"), "approval needs an explicit user-action source, never text")
        // the UI is the only caller outside tests
        for (path, text) in code("Sources/Jarvis") where text.contains("proposalService.approve(") { #expect(path.contains("/UI/"), "\(path) approves a proposal") }
    }

    @Test func autoActionsAreOnlyCreatedThroughTheTaskEngine() {
        let engine = code("Sources/Jarvis/Proactive").first { $0.path.hasSuffix("OpportunityEngine.swift") }?.text ?? ""
        #expect(engine.contains("tasks.submit(") && engine.contains("origin: origin"), "execution is a normal V0.4 task")
        for (path, text) in code("Sources/Jarvis/Proactive") { #expect(!text.contains("executeStep") && !text.contains("runCodeChange") && !text.contains("codeAttempt"), "\(path) must not run steps itself") }
    }

    @Test func noPollingOrTimersAnywhereInTheProactiveLayer() {
        for (path, text) in code("Sources/Jarvis/Proactive") {
            for bad in ["Task.sleep", "Timer.", "asyncAfter", "scheduledTimer", "DispatchSource"] { #expect(!text.contains(bad), "\(path) contains \(bad): reasoning must be event-driven") }
        }
    }

    @Test func noPaidProviderGitPushPurchaseOrCredentialExecutionExists() {
        for (path, text) in code("Sources/Jarvis/Proactive") {
            // OpportunityAssessor.swift holds the DETECTION keywords ("git push", "purchase", …) that make the policy stricter — words it looks for, not actions.
            for bad in ["git push", "\"push\""] where !path.hasSuffix("OpportunityAssessor.swift") { #expect(!text.contains(bad), "\(path) contains \(bad)") }
            for bad in ["StoreKit", "SecItem", "paidAPI", "openai.com", "anthropic.com", "URLSession"] { #expect(!text.contains(bad), "\(path) contains \(bad)") }
        }
        // the critical effects exist only as vocabulary the policy REFUSES to automate
        #expect(CapabilitySet.neverGranted.isSuperset(of: [.gitPush, .gitCommit, .purchase, .useNetwork, .useBrowser]))
    }

    @Test func theCapabilityVocabularyOfAModelIsRequestOnly() {
        // A model's requested capabilities go through `OpportunityAssessor.mergeModelAssessment` (union) and `OpportunityPolicy` — there is no setter that enables one.
        let assessor = code("Sources/Jarvis/Proactive").first { $0.path.hasSuffix("OpportunityAssessor.swift") }?.text ?? ""
        #expect(!assessor.contains("CapabilitySet(granted") && !assessor.contains(".granted"))
    }
}
