import Foundation

// MARK: - Natural requests that change a SETTING (V1.0 stabilisation fix 2)
//
// “Konuşma hızını biraz arttır”, “Wake word'ü kapat”, “Daha kısa cevap ver”, “Bana bundan sonra efendim diye hitap eder misin?” are requests to change one of the few user-controlled settings.
// They are recognised by a strict deterministic grammar (EN + TR, typed or spoken alike), validated and clamped, applied to the typed `Preferences` value, READ BACK, and only then reported — the sentence
// “I changed X” is produced from the value that was read back, never from the intention. A refusal is truthful too. Nothing here grants authority or touches approvals, permissions or security settings:
// the registry is closed and contains only presentation and voice conveniences. The language model is never asked.
//
// Decision (DEC-247): the address preference (“efendim”) is a PERSISTED SETTING (`addressStyle`), changed only by an explicit request like this one. Arbitrary conversation is never persisted, and Project
// Memory is never used for user preferences (it is per project and holds project knowledge).

enum SpeechRateChange: Equatable, Sendable {
    case faster(Double), slower(Double), reset, set(Double)
}

enum SettingsIntent: Equatable, Sendable {
    case speechRate(SpeechRateChange)
    case address(AddressStyle)
    case responseStyle(ResponseStyle)
    case wake(Bool)
    case launchAtLogin(Bool)
    case notifications(Bool)
    case voiceInput(Bool)
    case restore
    case lastChange
    case listSettings
    /// Voice-session controls that are NOT settings: “Dinlemeyi bırak” ends the open hands-free exchange; “Uyku moduna geç” pauses wake listening for now. Neither changes a stored setting, and neither is
    /// “Sus” (silence speech / stop generating) or “Görevi durdur” (stop the task) — those stay separate commands.
    case stopListening
    case sleepMode
}

@MainActor
protocol SettingsConversing: AnyObject {
    func recognizes(_ text: String) -> SettingsIntent?
    func perform(_ intent: SettingsIntent, language: ReplyLanguage) -> String
    /// A correction like “Hayır, yavaşlat” after a settings change has no subject of its own: the subject of the last change completes it (or nil).
    func completeFragment(_ fragment: String) -> String?
}

enum SettingsIntentParser {
    private static func tokens(_ raw: String) -> [String] {
        let f = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        return String(f.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") ? $0 : " " }).split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
    }

    static let rateRange = 0.7...1.4
    static let smallStep = 0.05, normalStep = 0.1, bigStep = 0.2

    static func recognize(_ raw: String) -> SettingsIntent? {
        let t = tokens(raw), f = t.joined(separator: " ")
        guard !t.isEmpty, t.count <= 14 else { return nil }
        func has(_ w: String...) -> Bool { w.contains { t.contains($0) } }
        func hasPrefix(_ p: String...) -> Bool { t.contains { w in p.contains { w.hasPrefix($0) } } }
        func phrase(_ p: String...) -> Bool { p.contains { f.contains($0) } }
        let on = hasPrefix("ac", "etkinlestir", "baslat") && !has("acik") || has("enable", "on") || phrase("turn on", "switch on", "start")
        let off = hasPrefix("kapat", "devre") || has("disable", "off") || phrase("turn off", "switch off", "stop using")
        // A question about a state (“is the speech faster?”, “what is the wake word?”) is not a request to change it.
        let stateQuestion = ["is", "are", "was", "does", "did", "what", "how", "why", "which", "ne", "neden", "nasil"].contains(t[0])
        let question = stateQuestion

        // An explicit memory command (“hatırla: …”, “remember that …”, “unut …”) is Project Memory's, never a settings request.
        if hasPrefix("hatirla", "unut", "remember", "forget") { return nil }
        // Voice-session controls (distinct from Sus / Görevi durdur / Wake word'ü kapat).
        if t.count <= 5, phrase("dinlemeyi birak", "dinlemeyi kes", "dinlemeyi durdur", "artik dinleme", "stop listening", "quit listening", "stop hands free", "cancel listening") { return .stopListening }
        if t.count <= 6, phrase("uyku moduna", "uykuya gec", "uyu artik", "go to sleep", "sleep mode", "go to standby", "standby mode") { return .sleepMode }
        // Introspection of settings: only REAL configurable settings are listed.
        if phrase("hangi ayarlari", "hangi ayarlar", "ayarlari ozellestir", "ayarlarini ozellestir", "which settings", "what settings", "settings can you", "settings you can") && (hasPrefix("ozellestir", "degistir", "ayarlayabil") || has("can", "change", "customize", "customise")) { return .listSettings }
        if phrase("hangi ayari degistir", "ayari degistirdin", "ayarlari degistirdin", "what setting did you", "which setting did you", "what did you just change", "what did you change") { return .lastChange }
        let restoreWords: Set<String> = ["eski", "haline", "getir", "dondur", "geri", "al", "bunu", "onu", "undo", "that", "it", "revert", "put", "back", "please", "lutfen", "eskisi", "gibi", "yap", "ayari", "ayarlari", "az", "onceki", "son", "yaptigin", "degisikligi", "degisikligini", "ayarini", "the", "last", "setting", "change"]
        if t.allSatisfy({ restoreWords.contains($0) }), phrase("eski haline", "geri al", "undo", "revert", "put it back", "put that back", "eskisi gibi") { return .restore }

        // Speech rate.
        let speechCtx = hasPrefix("konus") || has("speak", "speaking", "talk", "talking", "speech", "voice") || (hasPrefix("hiz") && has("ses", "sesin", "sesli", "tts"))
        let faster = hasPrefix("arttir", "artir", "hizlan", "hizli", "hizlandir", "yukselt") || has("faster", "quicker", "increase") || phrase("speed up", "speak up", "talk up")
        let slower = hasPrefix("azalt", "yavas", "yavaslat", "dusur") || has("slower", "decrease") || phrase("slow down", "speak down", "talk down")
        if speechCtx, !question, faster != slower {
            let big = has("cok", "much", "lot", "significantly", "epey"), small = has("biraz", "hafif", "hafifce", "slightly", "bit", "little", "kadar")
            let step = big ? bigStep : (small ? smallStep : normalStep)
            return .speechRate(faster ? .faster(step) : .slower(step))
        }
        if speechCtx, phrase("normal hiz", "varsayilan hiz", "varsayilana", "default speed", "normal speed", "reset speech", "hizini sifirla", "normale don", "normal hiza") { return .speechRate(.reset) }
        if speechCtx, let n = t.compactMap({ Double($0) }).first, rateRange.contains(n), hasPrefix("ayarla", "yap", "set") || has("to") { return .speechRate(.set(n)) }

        // Form of address (“efendim”).
        if has("efendim") {
            let stop = has("deme", "etme", "kullanma", "demeyi") || phrase("stop saying", "stop calling", "don t call", "dont call", "no more efendim", "without efendim", "efendimi birak")
            if stop { return .address(.off) }
            if phrase("daha az", "less often", "fewer", "az kullan", "ara sira", "seyrek") { return .address(.minimal) }
            if hasPrefix("hitap", "cagir") || phrase("call me", "address me", "refer to me", "efendim de", "efendim diye", "bana efendim") { return .address(.natural) }
        }

        // Response style (a persistent preference; a one-off “kısa söyle” is a depth request handled elsewhere).
        let answerNoun = (hasPrefix("cevap", "yanit", "yanitlar") || has("answers", "answer", "replies", "reply", "responses", "response"))
            && (has("ver", "verir", "verirsin", "olsun", "yap", "kullan", "tut", "istiyorum", "give", "keep", "make", "be", "please", "use", "want") || hasPrefix("kisalt")) && !has("seviyorum", "like", "love", "prefer", "begeniyorum")
        if answerNoun, hasPrefix("kisa", "ozet") || has("shorter", "short", "brief", "concise", "terse", "kisalt") { return .responseStyle(.concise) }
        if answerNoun, hasPrefix("detay", "ayrinti", "uzun", "kapsamli") || has("detailed", "longer", "thorough", "verbose") { return .responseStyle(.detailed) }
        if answerNoun, has("normal", "balanced", "dengeli", "standard") { return .responseStyle(.balanced) }

        // Switches.
        if (on != off) && !question {
            if phrase("wake word", "wakeword", "uyandirma", "wake kelime") || (has("wake") && has("word", "kelime", "kelimesi", "kelimeyi")) || phrase("jarvis kelimesi", "jarvis diyerek", "hands free", "eller serbest", "handsfree") { return .wake(on) }
            if phrase("launch at login", "login de", "giriste", "oturum acarken", "acilista", "bilgisayar acilinca", "bilgisayar acildiginda", "start at login", "open at login", "baslangicta") { return .launchAtLogin(on) }
            if hasPrefix("bildirim") || has("notifications", "notification") { return .notifications(on) }
            if phrase("ses girisi", "voice input", "sesli kontrol", "sesli komut", "voice control", "push to talk", "sesle kontrol") { return .voiceInput(on) }
        }
        return nil
    }
}

struct SettingChange: Equatable {
    var key: String            // stable id: speechRate | addressStyle | responseStyle | wake | launchAtLogin | notifications | voiceInput
    var title: (en: String, tr: String)
    var before: String
    var after: String
    var undo: () -> Void
    var at: Date
    static func == (a: SettingChange, b: SettingChange) -> Bool { a.key == b.key && a.before == b.before && a.after == b.after && a.at == b.at }
}

@MainActor
final class SettingsAssistant: SettingsConversing {
    let preferences: Preferences
    let ledger: StorageLedger
    /// Injectable seams: tests do not touch the real login item.
    var loginItemStatus: () -> LoginItemStatus = { LaunchAtLogin.status }
    var setLoginItem: (Bool) -> String? = { LaunchAtLogin.set($0) }
    var now: () -> Date = { Date() }
    /// Voice-session hooks (set by `AppContext`; the defaults describe a Mac with no hands-free stack, which is what unit tests of the grammar see).
    var wakeIsActive: () -> Bool = { false }
    var endListening: () -> Bool = { false }
    var enterSleep: () -> Bool = { false }
    var isSleeping: () -> Bool = { false }
    var resumeFromSleep: () -> Void = {}
    private(set) var changes: [SettingChange] = []
    static let historyLimit = 20

    init(preferences: Preferences, ledger: StorageLedger) { self.preferences = preferences; self.ledger = ledger }

    func recognizes(_ text: String) -> SettingsIntent? { SettingsIntentParser.recognize(text) }

    func completeFragment(_ fragment: String) -> String? {
        guard let key = changes.last?.key else { return nil }
        let subjects: [String: [String]] = ["speechRate": ["konuşma hızını", "speak"], "wake": ["wake word", "wake word"], "notifications": ["bildirimleri", "notifications"], "launchAtLogin": ["launch at login", "launch at login"],
                                           "voiceInput": ["ses girişini", "voice input"], "addressStyle": ["bana efendim", "efendim"], "responseStyle": ["cevapları", "answers"]]
        guard let s = subjects[key] else { return nil }
        for subject in s {
            let candidate = subject + " " + fragment
            if SettingsIntentParser.recognize(candidate) != nil { return candidate }
        }
        return nil
    }

    private func t(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }
    private func rate(_ v: Double) -> String { String(format: "%.2f×", v) }

    /// The closed registry shown by “which settings can you change?” — exactly what `perform` can do, nothing else.
    func settingLines(_ l: ReplyLanguage) -> [String] {
        let p = preferences
        return [
            t(l, "speech speed (currently \(rate(p.voiceSpeechRate)), range 0.70–1.40)", "konuşma hızı (şu an \(rate(p.voiceSpeechRate)), aralık 0,70–1,40)"),
            t(l, "form of address “efendim” (currently \(p.addressStyle.label))", "“efendim” hitabı (şu an \(p.addressStyle.label))"),
            t(l, "answer length (currently \(p.responseStyle.label))", "cevap uzunluğu (şu an \(p.responseStyle.label))"),
            t(l, "wake word (currently \(p.voiceWakeEnabled ? "on" : "off"))", "wake word (şu an \(p.voiceWakeEnabled ? "açık" : "kapalı"))"),
            t(l, "voice input (currently \(p.voiceEnabled ? "on" : "off"))", "ses girişi (şu an \(p.voiceEnabled ? "açık" : "kapalı"))"),
            t(l, "Launch at Login (currently \(loginItemStatus().label.lowercased()))", "Girişte başlat (şu an \(loginItemStatus().label.lowercased()))"),
            t(l, "task notifications (currently \(p.notifyOnTaskEvents ? "on" : "off"))", "görev bildirimleri (şu an \(p.notifyOnTaskEvents ? "açık" : "kapalı"))"),
        ]
    }

    private func record(_ key: String, _ title: (en: String, tr: String), before: String, after: String, undo: @escaping () -> Void) {
        changes.append(SettingChange(key: key, title: title, before: before, after: after, undo: undo, at: now()))
        if changes.count > Self.historyLimit { changes.removeFirst(changes.count - Self.historyLimit) }
    }

    func perform(_ intent: SettingsIntent, language l: ReplyLanguage) -> String {
        let p = preferences
        switch intent {
        case .listSettings:
            return t(l, "I can change these myself, on request: ", "İsteğiniz üzerine şunları kendim değiştirebilirim: ") + settingLines(l).joined(separator: "; ") + "."
                 + t(l, " Permissions, approvals and security settings are not among them — those stay yours.", " İzinler, onaylar ve güvenlik ayarları bunların arasında değil — onlar sizde kalır.")

        case .stopListening:
            if endListening() { return t(l, "Stopped listening. I am back to listening only for the wake word.", "Dinlemeyi bıraktım. Yalnızca wake kelimesini dinlemeye döndüm.") }
            if wakeIsActive() { return t(l, "I am not listening to you right now — only the local wake detector is running, for the word “Jarvis”. To switch that off too, say “turn off the wake word”.", "Şu an sizi dinlemiyorum — yalnızca “Jarvis” kelimesi için yerel wake algılayıcı çalışıyor. Onu da kapatmak için “wake word'ü kapat” deyin.") }
            return t(l, "I am not listening to anything right now.", "Şu an hiçbir şeyi dinlemiyorum.")

        case .sleepMode:
            if enterSleep() { return t(l, "Sleep mode: wake listening and the microphone are paused. The Wake Word setting is unchanged. Hold the right ⌥ key to talk, or say “turn on the wake word” / use the menu bar to wake me.", "Uyku modundayım: wake dinleme ve mikrofon duraklatıldı. Wake Word ayarı değişmedi. Konuşmak için sağ ⌥ tuşunu basılı tutun; beni uyandırmak için “wake word'ü aç” deyin ya da menü çubuğunu kullanın.") }
            if isSleeping() { return t(l, "I am already in sleep mode.", "Zaten uyku modundayım.") }
            return t(l, "Wake listening is not running, so there is nothing to put to sleep.", "Wake dinleme çalışmıyor; uykuya alınacak bir şey yok.")

        case .lastChange:
            guard let c = changes.last else { return t(l, "I have not changed any setting in this session.", "Bu oturumda hiçbir ayarı değiştirmedim.") }
            return t(l, "The last setting I changed: \(c.title.en) — from \(c.before) to \(c.after). Say “undo that” to put it back.", "Değiştirdiğim son ayar: \(c.title.tr) — \(c.before) iken \(c.after) yaptım. Geri almak için “eski haline getir” deyin.")

        case .restore:
            guard let c = changes.last else { return t(l, "There is no setting change to undo.", "Geri alınacak bir ayar değişikliği yok.") }
            c.undo()
            changes.removeLast()
            ledger.record(.persistedSetting, t(l, "\(c.title.en) restored to \(c.before)", "\(c.title.tr) \(c.before) değerine geri alındı"))
            return t(l, "Restored: \(c.title.en) is back to \(c.before).", "Geri aldım: \(c.title.tr) yine \(c.before).")

        case .speechRate(let change):
            let before = p.voiceSpeechRate
            let target: Double
            switch change {
            case .faster(let s): target = before + s
            case .slower(let s): target = before - s
            case .reset: target = 1.0
            case .set(let v): target = v
            }
            let range = SettingsIntentParser.rateRange
            let clamped = min(max((target * 100).rounded() / 100, range.lowerBound), range.upperBound)
            if abs(clamped - before) < 0.001 {
                switch change {
                case .faster: return t(l, "Speech is already at the fastest I allow (\(rate(before))).", "Konuşma zaten izin verdiğim en hızlı değerde (\(rate(before))).")
                case .slower: return t(l, "Speech is already at the slowest I allow (\(rate(before))).", "Konuşma zaten izin verdiğim en yavaş değerde (\(rate(before))).")
                default: return t(l, "Speech speed is already \(rate(before)).", "Konuşma hızı zaten \(rate(before)).")
                }
            }
            p.voiceSpeechRate = clamped
            guard abs(p.voiceSpeechRate - clamped) < 0.001 else { return t(l, "I could not change the speech speed.", "Konuşma hızını değiştiremedim.") }
            record("speechRate", ("speech speed", "konuşma hızı"), before: rate(before), after: rate(p.voiceSpeechRate)) { [weak p] in p?.voiceSpeechRate = before }
            ledger.record(.persistedSetting, t(l, "speech speed \(rate(p.voiceSpeechRate))", "konuşma hızı \(rate(p.voiceSpeechRate))"))
            let atLimit = clamped == range.upperBound || clamped == range.lowerBound
            return t(l, "Speech speed: \(rate(before)) → \(rate(p.voiceSpeechRate))\(atLimit ? " (the limit)" : ""). It applies from my next spoken reply. Say “undo that” to go back.",
                     "Konuşma hızı: \(rate(before)) → \(rate(p.voiceSpeechRate))\(atLimit ? " (sınır)" : ""). Bir sonraki sesli yanıttan itibaren geçerli. Geri almak için “eski haline getir” deyin.")

        case .address(let style):
            let before = p.addressStyle
            p.addressStyle = style
            guard p.addressStyle == style else { return t(l, "I could not change the form of address.", "Hitap biçimini değiştiremedim.") }
            record("addressStyle", ("form of address", "hitap biçimi"), before: before.label, after: style.label) { [weak p] in p?.addressStyle = before }
            ledger.record(.persistedSetting, t(l, "form of address: \(style.label)", "hitap biçimi: \(style.label)"))
            switch style {
            case .natural: return t(l, "Done: I will address you as “efendim” at natural moments (greeting, accepting a task, decisions) — not in every sentence. Saved as a setting (Address style: Natural); it stays after a restart.",
                                    "Tamam: sizi doğal anlarda (selamlama, görev kabulü, karar istemi) “efendim” diye anacağım — her cümlede değil. Ayar olarak kaydedildi (Hitap: Natural); yeniden başlatmadan sonra da durur.")
            case .minimal: return t(l, "Done: I will say “efendim” only when it matters (decisions and when you wake me). Saved as a setting.", "Tamam: “efendim” demeyi yalnızca önemli anlarda (karar istemi, uyandırma) kullanacağım. Ayar olarak kaydedildi.")
            case .off: return t(l, "Done: I will stop saying “efendim”. Saved as a setting.", "Tamam: “efendim” demeyi bırakıyorum. Ayar olarak kaydedildi.")
            }

        case .responseStyle(let style):
            let before = p.responseStyle
            if before == style { return t(l, "Answers are already set to \(style.label).", "Cevaplar zaten \(style.label) olarak ayarlı.") }
            p.responseStyle = style
            guard p.responseStyle == style else { return t(l, "I could not change the answer length.", "Cevap uzunluğunu değiştiremedim.") }
            record("responseStyle", ("answer length", "cevap uzunluğu"), before: before.label, after: style.label) { [weak p] in p?.responseStyle = before }
            ledger.record(.persistedSetting, t(l, "answer length: \(style.label)", "cevap uzunluğu: \(style.label)"))
            return t(l, "Answer length is now \(style.label) (saved as a setting). For just one answer, say “be brief” or “explain in detail”.", "Cevap uzunluğu artık \(style.label) (ayar olarak kaydedildi). Yalnızca tek bir cevap için “kısa söyle” veya “detaylı anlat” demeniz yeterli.")

        case .wake(let on):
            let before = p.voiceWakeEnabled
            if before == on, on, isSleeping() { resumeFromSleep(); return t(l, "Out of sleep mode: wake listening is back on.", "Uyku modundan çıktım: wake dinleme yeniden açık.") }
            if before == on { return on ? t(l, "The wake word is already on.", "Wake word zaten açık.") : t(l, "The wake word is already off.", "Wake word zaten kapalı.") }
            p.voiceWakeEnabled = on
            guard p.voiceWakeEnabled == on else { return t(l, "I could not change the wake word.", "Wake word'ü değiştiremedim.") }
            record("wake", ("wake word", "wake word"), before: before ? "on" : "off", after: on ? "on" : "off") { [weak p] in p?.voiceWakeEnabled = before }
            ledger.record(.persistedSetting, t(l, "wake word \(on ? "on" : "off")", "wake word \(on ? "açık" : "kapalı")"))
            if !on { return t(l, "Wake word is off: nothing listens for “Jarvis” any more (hold the right ⌥ key to talk). Saved as a setting.", "Wake word kapalı: artık “Jarvis” için hiçbir şey dinlemiyor (konuşmak için sağ ⌥ tuşunu basılı tutun). Ayar olarak kaydedildi.") }
            if !p.voiceEnabled { return t(l, "The wake word setting is on, but Voice input is OFF, so nothing listens yet. Say “turn on voice input” to start it.", "Wake word ayarı açık ama Ses girişi KAPALI, bu yüzden henüz hiçbir şey dinlemiyor. Başlatmak için “ses girişini aç” deyin.") }
            return t(l, "Wake word is on. The microphone is now used locally to listen for “Jarvis”; nothing is transcribed or sent anywhere before that. Saved as a setting.", "Wake word açık. Mikrofon artık yalnızca yerelde “Jarvis” kelimesini dinlemek için kullanılıyor; bundan önce hiçbir şey yazıya dökülmez veya gönderilmez. Ayar olarak kaydedildi.")

        case .voiceInput(let on):
            let before = p.voiceEnabled
            if before == on { return on ? t(l, "Voice input is already on.", "Ses girişi zaten açık.") : t(l, "Voice input is already off.", "Ses girişi zaten kapalı.") }
            p.voiceEnabled = on
            guard p.voiceEnabled == on else { return t(l, "I could not change voice input.", "Ses girişini değiştiremedim.") }
            record("voiceInput", ("voice input", "ses girişi"), before: before ? "on" : "off", after: on ? "on" : "off") { [weak p] in p?.voiceEnabled = before }
            ledger.record(.persistedSetting, t(l, "voice input \(on ? "on" : "off")", "ses girişi \(on ? "açık" : "kapalı")"))
            return on ? t(l, "Voice input is on: hold the right ⌥ key to talk. The microphone permission is asked for only when you first use it.", "Ses girişi açık: konuşmak için sağ ⌥ tuşunu basılı tutun. Mikrofon izni yalnızca ilk kullandığınızda istenir.")
                      : t(l, "Voice input is off. Typing still works.", "Ses girişi kapalı. Yazarak kullanmaya devam edebilirsiniz.")

        case .notifications(let on):
            let before = p.notifyOnTaskEvents
            if before == on { return on ? t(l, "Task notifications are already on.", "Görev bildirimleri zaten açık.") : t(l, "Task notifications are already off.", "Görev bildirimleri zaten kapalı.") }
            p.notifyOnTaskEvents = on
            guard p.notifyOnTaskEvents == on else { return t(l, "I could not change notifications.", "Bildirimleri değiştiremedim.") }
            record("notifications", ("task notifications", "görev bildirimleri"), before: before ? "on" : "off", after: on ? "on" : "off") { [weak p] in p?.notifyOnTaskEvents = before }
            ledger.record(.persistedSetting, t(l, "task notifications \(on ? "on" : "off")", "görev bildirimleri \(on ? "açık" : "kapalı")"))
            return on ? t(l, "Task notifications are on (task finished, failed or waiting for you — never with project content). macOS may still ask for permission the first time.", "Görev bildirimleri açık (görev bitti, başarısız oldu veya sizi bekliyor — proje içeriği olmadan). macOS ilk seferde izin isteyebilir.")
                      : t(l, "Task notifications are off.", "Görev bildirimleri kapalı.")

        case .launchAtLogin(let on):
            let before = loginItemStatus()
            if (before == .enabled) == on, before != .requiresApproval { return on ? t(l, "Launch at Login is already on.", "Girişte başlatma zaten açık.") : t(l, "Launch at Login is already off.", "Girişte başlatma zaten kapalı.") }
            if let problem = setLoginItem(on) { return t(l, "I could not change Launch at Login: \(problem)", "Girişte başlatmayı değiştiremedim: \(problem)") }
            let after = loginItemStatus()
            if on, after == .requiresApproval { return t(l, "macOS is waiting for your approval: open System Settings → General → Login Items and allow JARVIS. I cannot approve that for you.", "macOS onayınızı bekliyor: Sistem Ayarları → Genel → Oturum Açma Öğeleri'nden JARVIS'e izin verin. Bunu sizin yerinize onaylayamam.") }
            guard (after == .enabled) == on else { return t(l, "macOS did not apply the change (it reports: \(after.label)).", "macOS değişikliği uygulamadı (bildirilen durum: \(after.label)).") }
            let login = loginItemStatus
            record("launchAtLogin", ("Launch at Login", "Girişte başlat"), before: before.label.lowercased(), after: after.label.lowercased()) { [weak self] in _ = self?.setLoginItem(!on); _ = login }
            ledger.record(.persistedSetting, t(l, "Launch at Login \(on ? "on" : "off") (a macOS login item)", "Girişte başlat \(on ? "açık" : "kapalı") (macOS oturum açma öğesi)"))
            return on ? t(l, "Launch at Login is on: JARVIS will start when you log in. You can remove it any time in System Settings → General → Login Items.", "Girişte başlatma açık: oturum açtığınızda JARVIS başlar. İstediğiniz zaman Sistem Ayarları → Genel → Oturum Açma Öğeleri'nden kaldırabilirsiniz.")
                      : t(l, "Launch at Login is off.", "Girişte başlatma kapalı.")
        }
    }
}
