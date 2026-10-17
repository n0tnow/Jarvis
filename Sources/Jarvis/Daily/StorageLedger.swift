import Foundation

// MARK: - Where did that go? (V1.0 stabilisation fix 2)
//
// JARVIS has five different places something can live, and a user asking “bunu nereye kaydettin?” / “will you remember that?” must get the TRUE one — neither “I have no memory” nor “I saved it” said by habit:
//   PERSISTED SETTING · PROJECT MEMORY · TASK RECORD survive a restart; WORKING CONTEXT and the CONVERSATION live only while the app runs; NOT STORED is also a real answer.
// The ledger records only what a typed, successful write actually did (a setting changed and was read back, a memory record was admitted, a task was created). It writes nothing itself and is not a second source of truth.

enum StorageKind: String, Equatable, Sendable {
    case persistedSetting, projectMemory, taskRecord, workingContext, conversationOnly, notStored

    var survivesRestart: Bool { self == .persistedSetting || self == .projectMemory || self == .taskRecord }
    func label(_ l: ReplyLanguage) -> String {
        switch (self, l) {
        case (.persistedSetting, .tr): "KALICI AYAR"; case (.persistedSetting, .en): "PERSISTED SETTING"
        case (.projectMemory, .tr): "PROJE HAFIZASI"; case (.projectMemory, .en): "PROJECT MEMORY"
        case (.taskRecord, .tr): "GÖREV KAYDI"; case (.taskRecord, .en): "TASK RECORD"
        case (.workingContext, .tr): "ÇALIŞMA BAĞLAMI"; case (.workingContext, .en): "WORKING CONTEXT"
        case (.conversationOnly, .tr): "YALNIZCA SOHBET"; case (.conversationOnly, .en): "CONVERSATION ONLY"
        case (.notStored, .tr): "KAYDEDİLMEDİ"; case (.notStored, .en): "NOT STORED"
        }
    }
}

struct StorageEntry: Equatable, Sendable {
    var kind: StorageKind
    var subject: String          // short, user-facing: “konuşma hızı 1.10×”
    var turn: Int
    var at: Date
}

enum StorageQuestion: Equatable, Sendable { case whereSaved, isPersistent, willRemember }

@MainActor
final class StorageLedger {
    static let capacity = 40
    private(set) var entries: [StorageEntry] = []
    private(set) var turn = 0
    var now: () -> Date = { Date() }

    func beginTurn() { turn += 1 }
    func record(_ kind: StorageKind, _ subject: String) {
        entries.append(StorageEntry(kind: kind, subject: subject, turn: turn, at: now()))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
    /// The most recent entry written in an EARLIER turn than the current question (the question itself is turn `turn`).
    var previous: StorageEntry? { entries.last { $0.turn < turn } }

    func reply(to q: StorageQuestion, language l: ReplyLanguage) -> String {
        func t(_ en: String, _ trk: String) -> String { l == .tr ? trk : en }
        guard let e = previous, e.turn >= turn - 3 else {
            // Nothing was written by a typed action just before: that is the truth, not a gap to fill.
            return t("Nothing was saved just now. What you tell me in a chat stays only in this conversation, in memory, until JARVIS quits — it is not written anywhere. To keep something: a preference I can save as a setting (for example “call me efendim”); project knowledge goes to Project Memory with “remember that …” (a project folder must be chosen).",
                     "Az önce hiçbir şey kaydedilmedi. Sohbette söyledikleriniz JARVIS kapanana kadar yalnızca bu konuşmada, bellekte durur — hiçbir yere yazılmaz. Bir şeyin kalıcı olması için: bir tercihse ayar olarak kaydedebilirim (örneğin “bana efendim diye hitap et”); projeyle ilgili bilgi “hatırla: …” ile Proje Hafızası'na gider (bir proje klasörü seçili olmalı).")
        }
        let tag = "[\(e.kind.label(l))]"
        switch e.kind {
        case .persistedSetting:
            return t("\(tag) \(e.subject) — saved as a setting. It stays after JARVIS restarts; you can change it in Settings.", "\(tag) \(e.subject) — ayar olarak kaydedildi. JARVIS yeniden başlasa da geçerli kalır; Ayarlar'dan değiştirebilirsiniz.")
        case .projectMemory:
            return t("\(tag) \(e.subject) — stored in Project Memory for that project. It survives a restart; review or correct it on the Project Memory screen.", "\(tag) \(e.subject) — o proje için Proje Hafızası'na kaydedildi. Yeniden başlatmadan sonra da durur; Proje Hafızası ekranından görebilir veya düzeltebilirsiniz.")
        case .taskRecord:
            return t("\(tag) \(e.subject) — it is in the task history (kept after a restart), not in memory.", "\(tag) \(e.subject) — görev geçmişinde duruyor (yeniden başlatmadan sonra da), hafızada değil.")
        case .workingContext:
            return t("\(tag) \(e.subject) — kept only for this session so follow-ups work; it is not saved and is gone when JARVIS quits.", "\(tag) \(e.subject) — yalnızca bu oturum için, devam soruları çalışsın diye tutuluyor; kaydedilmedi ve JARVIS kapanınca silinir.")
        case .conversationOnly:
            return t("\(tag) \(e.subject) — only in this conversation; not saved.", "\(tag) \(e.subject) — yalnızca bu sohbette; kaydedilmedi.")
        case .notStored:
            return t("\(tag) \(e.subject)", "\(tag) \(e.subject)")
        }
    }
}

enum StorageQuestionParser {
    static func recognize(_ raw: String) -> StorageQuestion? {
        let f = fold(raw)
        guard f.split(separator: " ").count <= 10 else { return nil }
        func has(_ p: String...) -> Bool { p.contains { f.contains($0) } }
        if has("nereye kaydet", "nereye yazd", "nereye sakla", "where did you save", "where did you store", "where is that saved", "where did you put that", "nerede sakl", "where is it stored") { return .whereSaved }
        if has("kalici mi", "kalici olarak", "is that permanent", "is it permanent", "is that saved permanently", "kalici kaydet", "hafizaya kaydettin mi", "hafizaya aldin mi", "did you save that", "did you save it", "kaydettin mi", "saklad") && !has("kaydet:", "kaydet ki") { return has("kalici") ? .isPersistent : .whereSaved }
        if has("hatirlayacak misin", "hatirlar misin", "hatirlayacaksin", "will you remember", "will you remember that", "do you remember that", "bunu unutmayacak", "bunu aklinda tut", "will you keep that") { return .willRemember }
        return nil
    }
    private static func fold(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        return String(f.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ":") ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }
}
