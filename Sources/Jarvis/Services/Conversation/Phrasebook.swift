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
        case .agents: pick(l, "Opening the agents.", "Ajanları açıyorum.")
        case .research: pick(l, "Opening research.", "Araştırmayı açıyorum.")
        case .report: pick(l, "Opening the report.", "Raporu açıyorum.")
        case .system: pick(l, "Opening system.", "Sistemi açıyorum.")
        case .memory: pick(l, "Opening memory.", "Belleği açıyorum.")
        case .computer: pick(l, "Opening Computer Use.", "Bilgisayar kontrolünü açıyorum.")
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
        pick(l, "That is autonomous work (editing, running and iterating on a project), which isn't enabled yet — it belongs to the upcoming task engine. I can still explain, compare and answer questions about it. Nothing was started.",
             "Bu özerk bir iş (projeyi düzenleme, çalıştırma, tekrar deneme) ve henüz etkin değil — yaklaşan görev motoruna ait. Yine de bu konuda açıklama yapabilir, karşılaştırabilir, soruları yanıtlayabilirim. Hiçbir şey başlatılmadı.")
    }
    static func taskStarted(_ title: String, readOnly: Bool, _ l: ReplyLanguage) -> String {
        pick(l, "On it. I created the task “\(title)” and will plan it, \(readOnly ? "inspect the project" : "work through it, validate the result") and report back. Follow it in Tasks or Agents — say “stop” to cancel.",
             "Başlıyorum. “\(title)” görevini oluşturdum; planlayıp \(readOnly ? "projeyi inceleyeceğim" : "adım adım yürütüp sonucu doğrulayacağım") ve sonucu bildireceğim. Tasks veya Agents ekranından izleyebilirsiniz — iptal için “durdur” deyin.")
    }
    static func researchStarted(_ title: String, _ l: ReplyLanguage) -> String {
        pick(l, "Researching. I created the task “\(title)”: I will search, read the sources and write a cited report — nothing is downloaded, imported or bought. Follow it on the Research screen; say “stop” to cancel.",
             "Araştırıyorum. “\(title)” görevini oluşturdum: arayıp kaynakları okuyacak ve kaynaklı bir rapor yazacağım — hiçbir şey indirilmez, içe aktarılmaz ya da satın alınmaz. Research ekranından izleyebilirsiniz; iptal için “durdur” deyin.")
    }
    static func computerStarted(_ title: String, _ l: ReplyLanguage) -> String {
        pick(l, "On it — I'm operating your Mac for this (“\(title)”): I look at the app, act, and check the result at every step. Say “stop” any time, or hold ⌃⌥⌘.",
             "Tamam — bunun için Mac'inizi kullanıyorum (“\(title)”): uygulamaya bakar, hareket eder, her adımda sonucu doğrularım. İstediğiniz an “durdur” deyin ya da ⌃⌥⌘ tuşlarına basılı tutun.")
    }
    static func needsProject(_ l: ReplyLanguage) -> String {
        pick(l, "That is project work, so I need a project folder first. Open Tasks and choose one (Choose folder…), then ask again. Nothing was started.",
             "Bu bir proje işi; önce bir proje klasörü gerekiyor. Tasks ekranından klasör seçin, sonra tekrar isteyin. Hiçbir şey başlatılmadı.")
    }
    static func cannotPauseAutonomous(_ l: ReplyLanguage) -> String {
        pick(l, "Autonomous tasks can't be paused — say “stop” to cancel it, or let it finish.", "Özerk görevler duraklatılamaz — iptal için “durdur” deyin ya da bitmesini bekleyin.")
    }
    static func statusInterrupted(_ title: String, step: Int, of total: Int, _ l: ReplyLanguage) -> String {
        pick(l, "“\(title)” was interrupted at step \(step) of \(total). Say “resume” to continue it or “stop” to cancel it.", "“\(title)” \(step)/\(total). adımda kesildi. Devam için “devam et”, iptal için “durdur” deyin.")
    }
    static func generationStopped(_ l: ReplyLanguage) -> String { pick(l, "Stopped.", "Durduruldu.") }
    static func nothingGenerating(_ l: ReplyLanguage) -> String { pick(l, "Nothing is being generated right now.", "Şu anda üretilen bir yanıt yok.") }
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
