import Foundation

// MARK: - From a Decision to what the conversation layer does with it (V1.0 decision milestone)
//
// `DecisionPlanner.plan` is PURE: given a Decision, the user's text and a bundle of facts JARVIS already has, it says which EXISTING capability takes over — it performs nothing itself.
// `ConversationService` executes the plan by calling the same code that handled text before this milestone (the action service with its receipts and read-back, the readiness answers, Computer Use,
// continuity, the settings assistant, the router). Nothing in a plan approves, grants or claims completion; every executing branch still produces its own verified receipt (NO VERIFIED ACTION → NO
// COMPLETION CLAIM) and a plan for a `.blocked` or `.askFirst` decision never executes anything.

enum DecisionPlan: Equatable, Sendable {
    /// The existing pipeline continues exactly as it did before (status/readiness/continuity/research/memory handlers, then the router).
    case passThrough
    /// A grounded answer composed from facts (voice status, a visibility claim, a clarifying question, a refusal).
    case answer(String, tone: PlanTone)
    case systemStatus(StatusScope)
    /// A typed JARVIS action (navigation / HUD): executed by the action service, verified, answered from its receipt. nil = let the action grammar parse the text (applications, folders).
    case action(ActionIntent?)
    case settings
    case stopSpeech
    case cancelTask
    case openProject(KnownProject)
    /// Route this explicit sentence through continuity ("Hamam projesine devam et").
    case continueProject(sentence: String)
    /// A Computer Use request (media, look at the screen): handed to the existing Computer Use classifier.
    case computer(prompt: String)
    /// A corrected sentence, routed again from scratch like any typed request.
    case reroute(sentence: String)

    enum PlanTone: Equatable, Sendable { case normal, notice }
}

/// Everything the planner may read. Facts only; closures are read-only lookups.
struct DecisionFacts {
    var language: ReplyLanguage
    var source: UtteranceChannel
    var voice: VoiceStatusFacts
    var observations: [ObservedApp] = []
    var now: Date = Date()
    /// Structured fact from the running-application list (true / false / nil = unknown). Never evidence of visibility.
    var isAppRunning: (String) -> Bool? = { _ in nil }
    var projects: [KnownProject] = []
    var currentProjectRoot: String?
    var previousUserText: String = ""
    var previousInterpretation: String = "conversation"
    var computerAvailable: Bool = true
    /// The action grammar (application names resolved against installed apps), for correcting “open X”.
    var actionLookup: (String) -> ActionIntent? = { _ in nil }
    var pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var isKind: (String, String) -> Bool = { ProjectOpenResolver.markerExists(root: $0, kind: $1) }
}

enum DecisionPlanner {
    private static func t(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    static func plan(_ d: Decision, text: String, facts f: DecisionFacts) -> DecisionPlan {
        let l = f.language
        // Policy outranks confidence: a blocked request is refused here, whatever produced the decision.
        if d.gate == .blocked { return .answer(refusal(d, l), tone: .notice) }
        switch d.intent {
        case .voiceStatus:
            return .answer(VoiceStatusComposer.compose(f.voice, language: l), tone: .normal)
        case .systemStatus:
            return .systemStatus(scope(d.target))
        case .jarvisNavigation:
            return .action(typedHUDAction(d))
        case .macosApplicationAction:
            return .action(nil)
        case .stopSpeech: return .stopSpeech
        case .cancelTask: return .cancelTask
        case .settingsChange: return .settings
        case .projectOpen: return planOpen(d, f)
        case .projectTask:
            guard d.action == "continue" else { return .passThrough }          // delete / task / queue: the task engine's own policy and approvals decide
            guard let name = d.target, !name.isEmpty else { return .passThrough }
            // The NAME is resolved against the registry (closed case suffixes only): the sentence handed to continuity carries the registry's own name, never a guess and never "whatever is focused".
            switch ProjectOpenResolver.resolve(name: name, wantsLast: false, projects: f.projects, currentRoot: nil, pathExists: f.pathExists, isKind: f.isKind) {
            case .resolved(let p): return .continueProject(sentence: l == .tr ? "\(p.name) projesine devam et" : "continue the \(p.name) project")
            case .ambiguous(let candidates): return .answer(t(l, "Which project do you mean? I know: \(candidates.prefix(4).map(\.name).joined(separator: ", ")).", "Hangi projeyi kastediyorsunuz? Bildiklerim: \(candidates.prefix(4).map(\.name).joined(separator: ", "))."), tone: .notice)
            case .pathMissing(let p): return .answer(t(l, "I know “\(p.name)”, but its folder is not on disk any more, so I did not continue anything.", "“\(p.name)” projesini biliyorum ama klasörü artık diskte yok; bu yüzden hiçbir şeye devam etmedim."), tone: .notice)
            case .unknown, .noKnownProjects:
                // not in the registry under that name: the continuity grammar gets the explicit sentence (it knows more names than the registry list) — it asks if it cannot resolve it
                return .continueProject(sentence: l == .tr ? "\(name) projesine devam et" : "continue the \(name) project")
            }
        case .computerUse:
            switch d.action ?? "" {
            case "visibility_query":
                let target = d.target ?? "?"
                let running = ObservationGrounding.fold(target) == "browser" ? nil : f.isAppRunning(target)
                let answer = ObservationGrounding.evaluate(target: target, observations: f.observations, now: f.now)
                return .answer(ObservationGrounding.reply(answer, target: target, running: running, language: l), tone: answer.mayClaimVisible ? .normal : .notice)
            case "running_query":
                let target = d.target ?? "?"
                switch f.isAppRunning(target) {
                case true?: return .answer(t(l, "The application list says \(target) is running — that does not mean it is visible on screen.", "Uygulama listesine göre \(target) çalışıyor — bu, ekranda göründüğü anlamına gelmez."), tone: .normal)
                case false?: return .answer(t(l, "The application list says \(target) is not running.", "Uygulama listesine göre \(target) çalışmıyor."), tone: .normal)
                case nil: return .answer(t(l, "I cannot tell whether \(target) is running right now.", "\(target) şu an çalışıyor mu bilmiyorum."), tone: .notice)
                }
            case "media", "observe":
                return f.computerAvailable ? .computer(prompt: text) : .passThrough
            default: return .passThrough
            }
        case .correction: return planCorrection(d, text: text, f)
        case .projectQuery, .providerCapability, .research, .conversation, .unknown:
            return .passThrough
        }
    }

    // MARK: pieces

    private static func scope(_ target: String?) -> StatusScope {
        switch target { case "running": .running; case "features": .features; case "wake": .wake; default: .all }
    }

    /// The typed action for a JARVIS page / HUD decision. A page name that is not one of JARVIS' own pages yields nil (nothing is executed on a guess).
    static func typedHUDAction(_ d: Decision) -> ActionIntent? {
        switch d.action ?? "" {
        case "navigate": return d.target.flatMap { HUDSection(rawValue: $0.lowercased()) }.map { .navigate($0) }
        case "show_full": return .showFullHUD
        case "show_compact": return .showCompactHUD
        case "close": return .closeHUD
        default: return nil
        }
    }

    private static func refusal(_ d: Decision, _ l: ReplyLanguage) -> String {
        switch d.action ?? "" {
        case "git_push": return t(l, "I do not push to remotes — pushing is yours to do. I can prepare the changes and tell you what to run.", "Uzak depoya push yapmam — bu sizin işiniz. Değişiklikleri hazırlayabilir ve neyi çalıştıracağınızı söyleyebilirim.")
        case "git_commit": return t(l, "I do not create Git commits — that stays with you. I can leave the changes in the working tree.", "Git commit oluşturmam — bu sizde kalır. Değişiklikleri çalışma klasöründe bırakabilirim.")
        case "purchase": return t(l, "I never buy, pay for or subscribe to anything.", "Satın alma, ödeme ya da abonelik işlemlerini asla yapmam.")
        case "credential": return t(l, "I do not show, read or use passwords, keys or other credentials.", "Parolaları, anahtarları ya da diğer kimlik bilgilerini göstermem, okumam ve kullanmam.")
        default: return t(l, "I cannot do that: it is outside what I am allowed to do.", "Bunu yapamam: izin verilen işlerin dışında.")
        }
    }

    private static func planOpen(_ d: Decision, _ f: DecisionFacts) -> DecisionPlan {
        let l = f.language
        let resolution = ProjectOpenResolver.resolve(name: d.target, wantsLast: d.action == "open_last", projects: f.projects, currentRoot: f.currentProjectRoot, pathExists: f.pathExists, isKind: f.isKind)
        switch resolution {
        case .resolved(let p): return .openProject(p)
        case .ambiguous(let candidates):
            let names = candidates.prefix(4).map(\.name).joined(separator: ", ")
            return .answer(t(l, "Which project do you mean? I know: \(names).", "Hangi projeyi kastediyorsunuz? Bildiklerim: \(names)."), tone: .notice)
        case .unknown(let n, let known):
            if d.action == "open_bare" { return .passThrough }            // “Sofany'yi aç”: not a project — the application grammar (and its sound-shape fallback) gets the sentence unchanged
            let list = known.isEmpty ? "" : t(l, " Known projects: \(known.joined(separator: ", ")).", " Bildiğim projeler: \(known.joined(separator: ", ")).")
            return .answer(t(l, "I do not know a project called “\(n)”.", "“\(n)” adında bir proje tanımıyorum.") + list, tone: .notice)
        case .noKnownProjects:
            if d.action == "open_bare" { return .passThrough }
            return .answer(t(l, "I do not know any project yet. Choose a project folder in Settings first.", "Henüz hiçbir proje tanımıyorum. Önce Ayarlar'dan bir proje klasörü seçin."), tone: .notice)
        case .pathMissing(let p):
            return .answer(t(l, "I know “\(p.name)”, but its folder is not on disk any more, so I did not open anything.", "“\(p.name)” projesini biliyorum ama klasörü artık diskte yok; bu yüzden hiçbir şey açmadım."), tone: .notice)
        }
    }

    /// Spoken corrections. They only ever produce a sentence to route again, a clarifying question, or the existing action grammar — never an action of their own.
    private static func planCorrection(_ d: Decision, text: String, _ f: DecisionFacts) -> DecisionPlan {
        let l = f.language
        guard d.action == "restate" || d.action == "restate_replacing", let right = d.target, let r = SpokenRestatement.parse(text) else { return .passThrough }   // “Hayır, demek istediğim …” is resolved by the correction flow itself
        // 1. the mis-heard word is in the previous sentence: correct that sentence and route it again (“Sofany'yi aç” → “Safari'yi aç”)
        if let wrong = r.wrong, !f.previousUserText.isEmpty, let fixed = SpokenRestatement.apply(wrong: wrong, right: right, to: f.previousUserText) { return .reroute(sentence: fixed) }
        // 2. the previous turn was an action and the restated word is an application: open it
        if f.previousInterpretation.hasPrefix("action") {
            let probe = (l == .tr ? "\(right) uygulamasını aç" : "open \(right)")
            if case .launchApp? = f.actionLookup(probe) { return .reroute(sentence: probe) }
        }
        // 3. a whole restated sentence: route it
        if right.split(whereSeparator: { $0.isWhitespace }).count >= 2 { return .reroute(sentence: right) }
        // 4. a single name with nothing to apply it to: ask, never guess
        return .answer(t(l, "Understood: “\(right)”. What should I do with it?", "Anladım: “\(right)”. Bununla ne yapmamı istersiniz?"), tone: .notice)
    }
}
