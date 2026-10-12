import Foundation

/// V0.7 (DEC-065): approvals are decided ONLY with the HUD buttons — never by words, typed or spoken. Replying "yes" / "approve" / "onayla" while an
/// approval is pending does not approve anything (there is no code path from text to a decision); JARVIS says so instead of sending a bare "yes"
/// to a model. Typed and spoken input behave identically.
enum ApprovalGuard {
    private static let phrases: Set<String> = [
        "approve", "approved", "approve it", "approve that", "yes", "yes please", "yep", "yeah", "ok", "okay", "go ahead", "do it", "go for it", "confirm", "confirmed",
        "allow", "allow it", "accept", "proceed", "sure", "deny", "denied", "reject", "no", "nope", "cancel it", "decline",
        "onayla", "onaylıyorum", "onay", "evet", "tamam", "kabul", "kabul et", "izin ver", "yap", "yap bakalım", "devam", "reddet", "hayır", "hayir", "olur", "peki",
    ]

    /// Every word that can appear in such a short reply ("yes, do it", "ok go ahead", "evet onayla").
    private static let vocabulary: Set<String> = Set(phrases.flatMap { $0.split(separator: " ").map(String.init) }).union(["please", "lütfen", "jarvis", "it", "that", "this", "bunu", "şunu"])

    /// True only for a SHORT reply made entirely of approval/denial words. A real request that merely contains such a word is never caught.
    static func isApprovalUtterance(_ raw: String) -> Bool {
        let folded = raw.lowercased(with: Locale(identifier: "tr_TR")).map { $0.isLetter || $0 == " " ? $0 : " " }
        let tokens = String(folded).split(separator: " ").map(String.init)
        guard !tokens.isEmpty, tokens.count <= 5 else { return false }
        let content = tokens.filter { !["jarvis", "please", "lütfen"].contains($0) }
        guard !content.isEmpty else { return false }
        func known(_ t: String) -> Bool { vocabulary.contains(t) || vocabulary.contains(t.folding(options: .diacriticInsensitive, locale: nil)) }
        return content.allSatisfy(known)
    }

    static func notice(_ l: ReplyLanguage) -> String {
        l == .tr ? "Bunu sizin yerinize onaylayamam: onaylar yalnızca HUD'daki düğmelerle verilir (Görevler ekranı ya da onay kartı)."
                 : "I can't approve that for you: approvals are decided only with the buttons in the HUD (the approval card or the Tasks screen)."
    }
}
