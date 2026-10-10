import Foundation

/// All canned JARVIS wording (English + Turkish) in one place. No logic, no network.
enum Phrasebook {
    private static func pick(_ l: ReplyLanguage, _ en: String, _ tr: String) -> String { l == .tr ? tr : en }

    static func greeting(_ l: ReplyLanguage) -> String { pick(l, "Hello. What can I do for you?", "Merhaba. Sizin için ne yapabilirim?") }
    static func thanks(_ l: ReplyLanguage) -> String { pick(l, "You're welcome.", "Rica ederim.") }

    static func opening(_ section: HUDSection, _ l: ReplyLanguage) -> String {
        switch section {
        case .dashboard: pick(l, "Opening the dashboard.", "Ana ekranı açıyorum.")
        case .tasks: pick(l, "Opening your tasks.", "Görevleri açıyorum.")
        case .report: pick(l, "Opening the report.", "Raporu açıyorum.")
        case .system: pick(l, "Opening system.", "Sistemi açıyorum.")
        case .memory: pick(l, "Opening memory.", "Belleği açıyorum.")
        }
    }
    static func openingSettings(_ l: ReplyLanguage) -> String { pick(l, "Opening settings.", "Ayarları açıyorum.") }
    static func compactShown(_ l: ReplyLanguage) -> String { pick(l, "Showing the compact view.", "Kompakt görünümü gösteriyorum.") }
    static func fullShown(_ l: ReplyLanguage) -> String { pick(l, "Opening JARVIS.", "JARVIS'i açıyorum.") }
    static func hudClosed(_ l: ReplyLanguage) -> String { pick(l, "Closing. I'm still here in the menu bar.", "Kapatıyorum. Menü çubuğunda çalışmaya devam ediyorum.") }
    static func cleared(_ l: ReplyLanguage) -> String { pick(l, "Conversation cleared.", "Sohbet temizlendi.") }

    // Task control
    static func paused(_ title: String, _ l: ReplyLanguage) -> String { pick(l, "Task paused: “\(title)”.", "Görev duraklatıldı: “\(title)”.") }
    static func resumed(_ title: String, _ l: ReplyLanguage) -> String { pick(l, "Task resumed: “\(title)”.", "Görev sürdürüldü: “\(title)”.") }
    static func stopped(_ title: String, _ l: ReplyLanguage) -> String { pick(l, "Task stopped: “\(title)”.", "Görev durduruldu: “\(title)”.") }
    static func noTask(_ verb: String, _ l: ReplyLanguage) -> String { pick(l, "There is no active task to \(verb).", "Şu anda aktif bir görev yok.") }
    static func alreadyPaused(_ l: ReplyLanguage) -> String { pick(l, "The task is already paused.", "Görev zaten duraklatılmış.") }
    static func alreadyRunning(_ l: ReplyLanguage) -> String { pick(l, "The task is already running.", "Görev zaten çalışıyor.") }
    static func needsApproval(_ title: String, _ l: ReplyLanguage) -> String {
        pick(l, "The task is waiting for your approval (“\(title)”). Approve or deny it in the Full HUD.",
             "Görev onayınızı bekliyor (“\(title)”). Tam ekranda onaylayın veya reddedin.")
    }

    // Future intelligence
    static func reasoningUnavailable(_ l: ReplyLanguage) -> String {
        pick(l, "That needs an intelligence provider, and none is connected yet. I can still navigate, report status and control tasks — try “open the report” or “what are you doing?”.",
             "Bu istek bir zekâ sağlayıcısı gerektiriyor ve henüz bağlı değil. Yine de gezinebilir, durum bildirebilir ve görevleri yönetebilirim — “raporu aç” ya da “ne yapıyorsun?” deneyin.")
    }
    static func workerUnavailable(_ l: ReplyLanguage) -> String {
        pick(l, "That is work for a coding/automation worker, and no worker is connected yet. Nothing was started.",
             "Bu iş bir kodlama/otomasyon işçisi gerektiriyor ve henüz bağlı bir işçi yok. Hiçbir şey başlatılmadı.")
    }
    static func unsupported(_ l: ReplyLanguage) -> String { pick(l, "I didn't catch a request in that.", "Bunda bir istek anlayamadım.") }

    // Status
    static func statusWorking(_ title: String, step: Int, of total: Int, stepTitle: String, _ l: ReplyLanguage) -> String {
        pick(l, "I'm working on “\(title)” — step \(step) of \(total): \(stepTitle).", "“\(title)” görevi üzerinde çalışıyorum — adım \(step)/\(total): \(stepTitle).")
    }
    static func statusPaused(_ title: String, step: Int, of total: Int, _ l: ReplyLanguage) -> String {
        pick(l, "“\(title)” is paused at step \(step) of \(total).", "“\(title)” görevi \(step)/\(total). adımda duraklatıldı.")
    }
    static func statusWaiting(_ title: String, request: String?, _ l: ReplyLanguage) -> String {
        let extra = request.map { " (\($0))" } ?? ""
        return pick(l, "I'm waiting for your approval on “\(title)”\(extra).", "“\(title)” için onayınızı bekliyorum\(extra).")
    }
    static func statusNoTask(_ stateLabel: String, _ l: ReplyLanguage) -> String {
        pick(l, "No active task. My state is \(stateLabel.lowercased()).", "Aktif görev yok. Durumum: \(stateLabel.lowercased()).")
    }
}
