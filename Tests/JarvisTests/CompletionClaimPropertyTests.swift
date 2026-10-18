import Foundation
import Testing
@testable import Jarvis

// V1.0 background-intelligence pass — NO VERIFIED ACTION → NO COMPLETION CLAIM, as a property over the whole typed space (not a handful of examples):
// every ActionKind × every ReceiptStatus × every verification outcome × both languages × both executors. The sentence JARVIS says about an action is rendered from the receipt only; a completion wording
// may exist ONLY for a verified success, and every other state has its own honest wording. The model-text side is covered too: a claim in a model reply survives only with a verified fact.

private let allKinds: [ActionKind] = [.launchApp, .openFolder, .navigate, .showFullHUD, .showCompactHUD, .closeHUD, .computerGoal, .openProject]
private let allStatuses: [ReceiptStatus] = [.planned, .running, .succeeded, .failed, .cancelled, .needsApproval, .unverified]
private let verifications: [ActionVerification?] = [nil, ActionVerification(method: "m", passed: nil, detail: "no way to check"), ActionVerification(method: "m", passed: false, detail: "not found"), ActionVerification(method: "m", passed: true, detail: "ok")]

/// Wordings that assert the thing is done / open. They may be produced only for a claimable success.
private let completionMarkersEN = [" is open.", " is open in ", "is open in Finder", "Done and verified", "Closed.", "folder is open", "page is open", "screen is open", "view is open"]
private let completionMarkersTR = [" açık.", "Unity'de açık", "Finder'da açık", "Yapıldı ve doğrulandı", "Kapattım.", "klasörü açık", "sayfası açık", "ekranı açık", "görünüm açık"]

private func receipt(_ kind: ActionKind, _ status: ReceiptStatus, _ v: ActionVerification?, executor: String = "NSWorkspace") -> ActionReceipt {
    var r = ActionReceipt(kind: kind, target: "Hamam", executor: executor, now: Date(timeIntervalSince1970: 1_800_000_000))
    r.status = status; r.verification = v
    if status == .failed { r.error = "launch refused" }
    return r
}

@Suite("V1.0 background · completion claims are typed (property tests)")
struct CompletionClaimPropertyTests {
    @Test("a completion wording exists ONLY for a verified success — across every kind, status, verification and language")
    func onlyVerifiedSuccessClaims() {
        var combinations = 0
        for kind in allKinds { for status in allStatuses { for v in verifications { for exec in ["NSWorkspace", "Unity editor"] {
            let r = receipt(kind, status, v, executor: exec)
            for (lang, markers) in [(ReplyLanguage.en, completionMarkersEN), (ReplyLanguage.tr, completionMarkersTR)] {
                combinations += 1
                let said = ActionPhrasebook.render(r, language: lang)
                let claims = markers.contains { said.contains($0) }
                if r.successIsClaimable { #expect(claims, Comment(rawValue: "a verified success must be said as done: \(kind) \(lang) → \(said)")) }
                else { #expect(!claims, Comment(rawValue: "UNVERIFIED claim: \(kind) \(status) verification=\(String(describing: v?.passed)) \(lang) → \(said)")) }
                #expect(!said.isEmpty && said.count < 400)
            }
        } } } }
        #expect(combinations == allKinds.count * allStatuses.count * verifications.count * 2 * 2)
    }

    @Test("every non-success state says what it is: failed names the failure, unverified says it could not confirm, approval says the HUD decides, cancelled says cancelled")
    func honestWording() {
        for kind in allKinds {
            for lang in [ReplyLanguage.en, .tr] {
                let failed = ActionPhrasebook.render(receipt(kind, .failed, nil), language: lang)
                #expect(failed.contains("launch refused"), Comment(rawValue: "\(kind) \(lang): \(failed)"))
                let unverified = ActionPhrasebook.render(receipt(kind, .unverified, ActionVerification(method: "m", passed: nil, detail: "no way to check")), language: lang)
                #expect(lang == .en ? unverified.contains("could not confirm") : unverified.contains("doğrulayamadım"), Comment(rawValue: unverified))
                let approval = ActionPhrasebook.render(receipt(kind, .needsApproval, nil), language: lang)
                #expect(lang == .en ? approval.contains("does not approve") : approval.contains("onay vermez"), Comment(rawValue: approval))
                let cancelled = ActionPhrasebook.render(receipt(kind, .cancelled, nil), language: lang)
                #expect(lang == .en ? cancelled.hasPrefix("Cancelled") : cancelled.hasPrefix("İptal"), Comment(rawValue: cancelled))
            }
        }
    }

    @Test("a 'succeeded' status without a passing verification is demoted: the receipt's own mutators can never produce an unverifiable success")
    func mutators() {
        for passed in [nil, false] as [Bool?] {
            var r = ActionReceipt(kind: .launchApp, target: "Safari", executor: "NSWorkspace")
            r.start()
            r.succeed(ActionVerification(method: "m", passed: passed, detail: "d"))
            #expect(r.status == .unverified && !r.successIsClaimable)
        }
        var ok = ActionReceipt(kind: .launchApp, target: "Safari", executor: "NSWorkspace"); ok.start()
        ok.succeed(ActionVerification(method: "m", passed: true, detail: "running"))
        #expect(ok.status == .succeeded && ok.successIsClaimable)
        var failed = ActionReceipt(kind: .openFolder, target: "Downloads", executor: "NSWorkspace"); failed.start()
        failed.fail(String(repeating: "x", count: 900))
        #expect(failed.status == .failed && (failed.error?.count ?? 0) == 200 && !failed.successIsClaimable)
        // a hand-forged succeeded receipt with a failing check is still not claimable
        var forged = receipt(.launchApp, .succeeded, ActionVerification(method: "m", passed: false, detail: "gone"))
        #expect(!forged.successIsClaimable)
        forged.verification = nil
        #expect(!forged.successIsClaimable)
    }

    @Test("task completion has the same rule: a model reply that says a task or build finished survives only with a verified completed state, in both languages")
    func taskClaims() {
        let replies = ["The build completed successfully.", "Görev tamamlandı.", "All tests passed.", "Testler geçti.", "The task is done.", "Proje hazır."]
        for reply in replies {
            let none = ResponseClaimFirewall.review(reply: reply, provenance: .modelGenerated, facts: [], language: .en)
            if case .allow = none { Issue.record("an unbacked task claim was allowed: \(reply)") }
        }
        // a progress percentage from a model is never evidence
        for reply in ["Görev %80 tamamlandı.", "The task is 80% complete."] {
            if case .allow = ResponseClaimFirewall.review(reply: reply, provenance: .modelGenerated, facts: [.taskState(title: "Refactor", state: "running", step: "s3")], language: .tr) { Issue.record("a percentage was allowed: \(reply)") }
        }
        // a running task does not back a completion claim; a completed one with the same title does
        let backedBy: [StructuredFact] = [.taskState(title: "Refactor", state: "completed", step: nil)]
        let running: [StructuredFact] = [.taskState(title: "Refactor", state: "running", step: "s2")]
        #expect(ResponseClaimFirewall.review(reply: "The Refactor task is completed.", provenance: .modelGenerated, facts: backedBy, language: .en) == .allow)
        if case .allow = ResponseClaimFirewall.review(reply: "The Refactor task is completed.", provenance: .modelGenerated, facts: running, language: .en) { Issue.record("a running task backed a completion claim") }
        // facts about ANOTHER task back nothing
        let other: [StructuredFact] = [.taskState(title: "Docs", state: "completed", step: nil)]
        if case .allow = ResponseClaimFirewall.review(reply: "The Refactor task is completed.", provenance: .modelGenerated, facts: other, language: .en) { Issue.record("another task's completion backed this claim") }
    }

    @Test("a model reply claiming an action survives only with a VERIFIED action fact naming the same target; unverified or different-target facts never back it")
    func actionClaims() {
        let claims = ["Safari'yi açtım.", "I opened Safari.", "Safari'yi kapattım.", "I have closed Safari."]
        for reply in claims {
            for facts in [[StructuredFact](), [.actionResult(kind: "launch", target: "Safari", verified: false, detail: "x")], [.actionResult(kind: "launch", target: "Finder", verified: true, detail: "x")]] {
                if case .allow = ResponseClaimFirewall.review(reply: reply, provenance: .modelGenerated, facts: facts, language: .en) { Issue.record("an action claim was allowed without a verified fact: \(reply)") }
            }
            #expect(ResponseClaimFirewall.review(reply: reply, provenance: .modelGenerated, facts: [.actionResult(kind: "x", target: "Safari", verified: true, detail: "")], language: .en) == .allow, Comment(rawValue: reply))
        }
        // what JARVIS composed itself is never second-guessed, and a harmless answer is left alone
        #expect(ResponseClaimFirewall.review(reply: "Safari'yi açtım.", provenance: .groundedFacts, facts: [], language: .tr) == .allow)
        #expect(ResponseClaimFirewall.findings(in: "Swift'te bir dizi şöyle tanımlanır: let a = [1, 2, 3].").isEmpty)
    }
}
