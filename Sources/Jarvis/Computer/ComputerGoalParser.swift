import Foundation

// MARK: - Applications JARVIS knows by name (bundle identifier first; display-name guessing is the fallback)

struct KnownApp: Sendable {
    var aliases: [String]               // folded
    var bundleID: String
    var display: String
}

enum AppCatalog {
    static let known: [KnownApp] = [
        KnownApp(aliases: ["xcode"], bundleID: "com.apple.dt.Xcode", display: "Xcode"),
        KnownApp(aliases: ["finder"], bundleID: "com.apple.finder", display: "Finder"),
        KnownApp(aliases: ["system settings", "system preferences", "sistem ayarlari", "sistem tercihleri"], bundleID: "com.apple.systempreferences", display: "System Settings"),
        KnownApp(aliases: ["blender"], bundleID: "org.blenderfoundation.blender", display: "Blender"),
        KnownApp(aliases: ["unity hub", "unityhub"], bundleID: "com.unity3d.unityhub", display: "Unity Hub"),
        KnownApp(aliases: ["unity", "unity editor"], bundleID: "com.unity3d.UnityEditor5.x", display: "Unity"),
        KnownApp(aliases: ["safari"], bundleID: "com.apple.Safari", display: "Safari"),
        KnownApp(aliases: ["chrome", "google chrome"], bundleID: "com.google.Chrome", display: "Google Chrome"),
        KnownApp(aliases: ["vs code", "vscode", "visual studio code"], bundleID: "com.microsoft.VSCode", display: "Visual Studio Code"),
        KnownApp(aliases: ["terminal"], bundleID: "com.apple.Terminal", display: "Terminal"),
        KnownApp(aliases: ["textedit"], bundleID: "com.apple.TextEdit", display: "TextEdit"),
        KnownApp(aliases: ["notes", "notlar"], bundleID: "com.apple.Notes", display: "Notes"),
        KnownApp(aliases: ["calculator", "hesap makinesi"], bundleID: "com.apple.calculator", display: "Calculator"),
        KnownApp(aliases: ["preview", "onizleme"], bundleID: "com.apple.Preview", display: "Preview"),
        KnownApp(aliases: ["activity monitor", "etkinlik monitoru"], bundleID: "com.apple.ActivityMonitor", display: "Activity Monitor"),
        KnownApp(aliases: ["jarvis fixture", "fixture app", "fixture"], bundleID: "com.jarvis.fixture", display: "JARVIS Fixture"),
    ]

    /// First known app mentioned in `tokens` (Turkish suffixes tolerated: "xcodeu", "finderda", "unityye").
    static func match(tokens: [String]) -> (app: KnownApp, range: Range<Int>)? {
        var best: (KnownApp, Range<Int>)?
        for app in known {
            for alias in app.aliases {
                let a = alias.split(separator: " ").map(String.init)
                guard !a.isEmpty, tokens.count >= a.count else { continue }
                for start in 0...(tokens.count - a.count) {
                    var ok = true
                    for (k, w) in a.enumerated() {
                        let tok = tokens[start + k]
                        let last = k == a.count - 1
                        if tok == w { continue }
                        if last, w.count >= 4, tok.hasPrefix(w), tok.count - w.count <= 4 { continue }
                        ok = false; break
                    }
                    if ok, best == nil || a.count > (best!.1.count) { best = (app, start..<(start + a.count)) }
                }
            }
        }
        return best.map { (app: $0.0, range: $0.1) }
    }

    /// An installed application with this exact (folded) name. Used for names JARVIS does not know. Directory listing only; nothing is launched.
    static func installed(named raw: String, directories: [String] = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications", "/Applications/Utilities"]) -> AppRef? {
        let want = ComputerText.fold(raw).trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty, want.count <= 60 else { return nil }
        let fm = FileManager.default
        for d in directories {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for item in items where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                if ComputerText.fold(name) == want, let b = Bundle(path: d + "/" + item)?.bundleIdentifier { return AppRef(bundleID: b, name: name) }
            }
        }
        return nil
    }
}

extension AppRef {
    func matches(_ s: ApplicationSnapshot) -> Bool {
        if let b = bundleID {
            if s.bundleID == b { return true }
            if b == "com.unity3d.UnityEditor5.x", s.bundleID?.hasPrefix("com.unity3d.UnityEditor") == true { return true }
            return false
        }
        if let n = name { return ComputerText.fold(s.name) == ComputerText.fold(n) }
        return false
    }
}

// MARK: - Goal → typed actions (deterministic; EN + TR)

struct GoalStep: Equatable, Sendable {
    var title: String                  // "Opening Xcode"
    var actions: [ComputerAction]
}

struct ParsedGoal: Equatable, Sendable {
    var steps: [GoalStep]
    var apps: [AppRef]
    var language: ReplyLanguage
    var capability: CapabilityChoice
}

enum GoalClassification: Equatable, Sendable {
    case computer(ParsedGoal)
    /// A stronger mechanism owns this goal: the normal routing continues (task engine / Unity / research); Computer Use does nothing.
    case delegate(CapabilityChoice)
    /// An explicit request for something Computer Use must never do (press Buy, run a command in Terminal, type a password…).
    case refused(String)
    case notComputer
}

enum ComputerGoalParser {
    private static let openVerbs: Set<String> = ["open", "launch", "start", "ac", "baslat", "calistir"]
    private static let switchVerbs: Set<String> = ["switch", "activate", "focus", "gec", "gecis"]
    private static let showVerbs: Set<String> = ["show", "reveal", "display", "goster", "ac"]
    private static let clickVerbs: Set<String> = ["click", "press", "tap", "push", "hit", "tikla", "bas", "sec", "select", "choose"]
    private static let readVerbs: Set<String> = ["read", "inspect", "check", "oku", "bak", "look"]
    private static let saveVerbs: Set<String> = ["save", "kaydet"]
    private static let folderWords: Set<String> = ["folder", "directory", "klasor", "klasoru", "dizin", "repo", "repository", "project", "proje", "projeyi", "projesini", "file", "dosya", "dosyayi"]

    static func classify(_ raw: String, context: GoalContext) -> GoalClassification {
        let norm = InputNormalizer.normalize(raw)
        let language = norm.language
        let tokens = ComputerText.tokens(raw)
        guard !tokens.isEmpty, tokens.count <= 40 else { return .notComputer }
        let words = Set(tokens)

        // A. explicit forbidden things first — never a task, never delegated
        if CapabilityResolver.isTerminalBypass(raw) {
            return .refused(language == .tr ? "Başka bir uygulamaya komut yazdırarak komut politikasını aşamam. Onaylı komutlar yalnızca görev motoru üzerinden çalışır." : "I won't type commands into Terminal or another app: that would bypass the command policy. Approved commands only run through the task engine.")
        }
        if let why = forbiddenClick(tokens, raw: raw) {
            return .refused(language == .tr ? "Bunu yapmam: \(why). Gerekirse kendin yapabilirsin." : "I won't do that: \(why). You can do it yourself if you want it.")
        }
        // B. stronger mechanisms own the goal
        if let stronger = CapabilityResolver.strongerMechanism(for: raw, context: context) { return .delegate(stronger) }

        // C. Computer Use patterns
        guard let plan = parse(tokens: tokens, raw: raw, language: language, context: context) else { return .notComputer }
        _ = words
        return .computer(plan)
    }

    /// "click Buy", "press the Send button", "install it"… as explicit GUI requests.
    private static func forbiddenClick(_ t: [String], raw: String) -> String? {
        guard !Set(t).isDisjoint(with: clickVerbs) else { return nil }
        let label = ConsequenceClassifier.classify(label: raw.replacingOccurrences(of: "click", with: "", options: .caseInsensitive).replacingOccurrences(of: "press", with: "", options: .caseInsensitive))
        switch label {
        case .purchase, .accountAction, .credentialEntry, .install, .privacyGrant, .securityChange, .sendMessage, .publish, .forceQuit: return "that means \(label.label)"
        default: return nil
        }
    }

    // MARK: Patterns

    private static func parse(tokens t: [String], raw: String, language: ReplyLanguage, context: GoalContext) -> ParsedGoal? {
        let words = Set(t)
        let appMatch = AppCatalog.match(tokens: t)
        let known = appMatch.map { AppRef(bundleID: $0.app.bundleID, name: $0.app.display) }
        let acc = CapabilityChoice(mechanism: .accessibility, engine: "macOS Accessibility / NSWorkspace", reason: "No typed JARVIS capability covers this, so it is done through native macOS Accessibility and NSWorkspace — observed and verified step by step.")

        func goal(_ steps: [GoalStep], apps: [AppRef]) -> ParsedGoal { ParsedGoal(steps: steps, apps: apps, language: language, capability: acc) }
        func launchSteps(_ app: AppRef, verb: String) -> [GoalStep] {
            let id = app.bundleID ?? ""
            let checks: [Check] = id.isEmpty ? [] : [.appFrontmost(bundleID: id)]
            return [GoalStep(title: language == .tr ? "\(app.display) açılıyor" : "Opening \(app.display)", actions: [
                ComputerAction(kind: .launchApplication, target: ActionTarget(app: app), checks: id.isEmpty ? [] : [.appRunning(bundleID: id)], summary: "Launch \(app.display)"),
                ComputerAction(kind: .activateApplication, target: ActionTarget(app: app), checks: checks, summary: "Activate \(app.display)"),
            ])]
        }

        // 1. System Settings panes: "show me the microphone permission page", "open accessibility settings"
        if let pane = settingsPane(in: t, words: words), words.contains("page") || words.contains("settings") || words.contains("permission") || words.contains("ayarlari") || words.contains("izin") || words.contains("izni") || words.contains("sayfasi") || words.contains("privacy") {
            let app = AppRef(bundleID: SurfacePolicy.systemSettings, name: "System Settings")
            return goal([GoalStep(title: language == .tr ? "Sistem Ayarları açılıyor" : "Opening System Settings", actions: [
                ComputerAction(kind: .openSettingsPane, target: ActionTarget(app: app), pane: pane, checks: [.appFrontmost(bundleID: SurfacePolicy.systemSettings)], summary: "Open the \(pane.titleHint) pane"),
            ])], apps: [app])
        }

        // 2. reveal a folder/file in Finder
        if (words.contains("finder") || appMatch?.app.bundleID == SurfacePolicy.finder), !words.isDisjoint(with: folderWords) || !words.isDisjoint(with: showVerbs) {
            if let path = explicitPath(in: raw) ?? (referencesProject(t) ? context.projectRoot : nil) {
                let name = (path as NSString).lastPathComponent
                let finder = AppRef(bundleID: SurfacePolicy.finder, name: "Finder")
                return goal([GoalStep(title: language == .tr ? "Finder'da gösteriliyor" : "Showing it in Finder", actions: [
                    ComputerAction(kind: .revealFile, target: ActionTarget(app: finder), path: path, checks: [.appFrontmost(bundleID: SurfacePolicy.finder), .finderShows(name: name)], summary: "Reveal “\(name)” in Finder"),
                ])], apps: [finder])
            }
            if !words.isDisjoint(with: openVerbs.union(switchVerbs)), !words.isDisjoint(with: ["finder"]) { return goal(launchSteps(AppRef(bundleID: SurfacePolicy.finder, name: "Finder"), verb: "open"), apps: [AppRef(bundleID: SurfacePolicy.finder, name: "Finder")]) }
        }

        // 3. open the JARVIS project / a file in an application ("open the JARVIS project in Xcode")
        if let app = known, words.contains("in") || words.contains("with") || words.contains("de") || words.contains("da"), referencesProject(t) || explicitPath(in: raw) != nil, !words.isDisjoint(with: openVerbs) {
            if let path = explicitPath(in: raw) ?? context.projectRoot {
                let target = bestProjectDocument(under: path) ?? path
                return goal(launchSteps(app, verb: "open") + [GoalStep(title: language == .tr ? "Proje açılıyor" : "Opening the project", actions: [
                    ComputerAction(kind: .openFile, target: ActionTarget(app: app), path: target, checks: [.appFrontmost(bundleID: app.bundleID ?? "")], summary: "Open “\((target as NSString).lastPathComponent)” in \(app.display)"),
                ])], apps: [app])
            }
        }

        // 4. settings / preferences of an app: "open Xcode Settings", "Xcode ayarlarini ac"
        if let app = known, !words.isDisjoint(with: ["settings", "preferences", "ayarlar", "ayarlari", "tercihler", "tercihlerini"]), !words.isDisjoint(with: openVerbs.union(showVerbs)), app.bundleID != SurfacePolicy.systemSettings {
            let menu = ActionTarget(app: app, menuPath: ["@app", "Settings"])
            return goal(launchSteps(app, verb: "open") + [GoalStep(title: language == .tr ? "Ayarlar açılıyor" : "Opening Settings", actions: [
                ComputerAction(kind: .selectMenuItem, target: menu, checks: [.newWindow(bundleID: app.bundleID ?? "")], summary: "Choose Settings… in the \(app.display) menu"),
            ])], apps: [app])
        }

        // 5. click/press/select a named control: "click the Render Properties tab", "press Run in Xcode"
        if !words.isDisjoint(with: clickVerbs), let label = controlLabel(raw: raw, tokens: t, appRange: appMatch?.range) {
            let app = known ?? AppRef()
            let role = controlRole(t)
            let target = ActionTarget(app: app, role: role, title: label)
            let id = app.bundleID
            return goal((known.map { launchSteps($0, verb: "activate") } ?? []) + [GoalStep(title: language == .tr ? "“\(label)” seçiliyor" : "Pressing “\(label)”", actions: [
                ComputerAction(kind: .pressElement, target: target, checks: [.stateChanged] + (id.map { [Check.appFrontmost(bundleID: $0)] } ?? []), summary: "Press “\(label)”"),
            ])], apps: known.map { [$0] } ?? [])
        }

        // 5b. enter quoted text into a named field: `type "hello" into the Name field in Xcode` (the text is the user's own words; secrets and passwords are refused by the policy)
        if !words.isDisjoint(with: ["type", "write", "enter", "yaz", "gir"]), let text = quoted(raw), !words.isDisjoint(with: ["field", "box", "alan", "alana", "into", "in", "to"]) {
            let tail = raw.components(separatedBy: text).last ?? ""
            let tailTokens = ComputerText.tokens(tail).filter { !["into", "in", "to", "the", "field", "box", "text", "alan", "alana", "named", "called"].contains($0) }
            let appTokenRange = AppCatalog.match(tokens: tailTokens)?.range
            let labelTokens = tailTokens.enumerated().filter { !(appTokenRange?.contains($0.offset) ?? false) }.map(\.element)
            if !labelTokens.isEmpty, labelTokens.count <= 3 {
                let label = originalCase(of: labelTokens.joined(separator: " "), in: tail) ?? labelTokens.joined(separator: " ")
                let app = known ?? AppRef()
                return goal((known.map { launchSteps($0, verb: "activate") } ?? []) + [GoalStep(title: language == .tr ? "Metin giriliyor" : "Entering text", actions: [
                    ComputerAction(kind: .setText, target: ActionTarget(app: app, role: "textField", title: label), text: text, summary: "Enter text in “\(label)”"),
                ])], apps: known.map { [$0] } ?? [])
            }
        }

        // 6. save the current document
        if !words.isDisjoint(with: saveVerbs), words.contains("document") || words.contains("file") || words.contains("belge") || words.contains("dosyayi") || words.contains("this") || words.contains("it") {
            let app = known ?? AppRef()
            return goal([GoalStep(title: language == .tr ? "Kaydediliyor" : "Saving", actions: [
                ComputerAction(kind: .selectMenuItem, target: ActionTarget(app: app, menuPath: ["File", "Save"]), checks: [.stateChanged], summary: "Choose File → Save"),
            ])], apps: known.map { [$0] } ?? [])
        }

        // 6b. Xcode navigators: "open the issue navigator in Xcode" → the allowlisted ⌘1…⌘9 shortcut of that navigator (semantic navigation, not hunting for a control)
        if let app = known, app.bundleID == "com.apple.dt.Xcode", words.contains("navigator") || words.contains("navigatoru") || words.contains("gezgini"),
           let adapter = AdapterRegistry.adapter(for: app.bundleID), let nav = adapter.navigation.first(where: { words.contains($0.key.split(separator: " ").first.map(String.init) ?? $0.key) }) {
            let id = app.bundleID ?? ""
            return goal(launchSteps(app, verb: "activate") + [GoalStep(title: language == .tr ? "\(nav.key.capitalized) gezgini açılıyor" : "Opening the \(nav.key) navigator", actions: [
                ComputerAction(kind: .pressShortcut, target: ActionTarget(app: app), chord: nav.value, checks: [.stateChanged, .appFrontmost(bundleID: id)], summary: "Open the \(nav.key) navigator (\(nav.value.display))"),
            ])], apps: [app])
        }

        // 7. read UI state: "read the current Console state in Unity" (when V0.6 does not own it), "what is open in Xcode"
        if !words.isDisjoint(with: readVerbs), let app = known {
            return goal(launchSteps(app, verb: "activate") + [GoalStep(title: language == .tr ? "Arayüz inceleniyor" : "Reading the interface", actions: [
                ComputerAction(kind: .observe, target: ActionTarget(app: app), summary: "Observe \(app.display)"),
            ])], apps: [app])
        }

        // 7b. “Ekranıma bak” / “Look at my screen” / “what is on my screen”: an explicit REQUEST to look. It observes the frontmost application window through Accessibility (labels only, one observation,
        // no continuous watching); a window picture is only taken by the separate, permission-gated vision path. A QUESTION about the ability (“can you see my screen?”) never gets here — it is answered from state.
        let screenWords: Set<String> = ["ekran", "ekrani", "ekranim", "ekranima", "ekranimi", "ekranimda", "ekraninda", "ekranda", "screen", "desktop", "masaustu", "masaustume", "masaustumu"]
        let lookVerbs: Set<String> = ["bak", "bakar", "bakin", "bakarmisin", "incele", "inceler", "look", "describe", "check", "inspect", "analyze", "analiz", "oku", "read", "goster", "show"]
        if t.count <= 8, !words.isDisjoint(with: screenWords), words.isDisjoint(with: clickVerbs), !words.isDisjoint(with: lookVerbs) || (words.contains("var") && (words.contains("ne") || words.contains("neler"))) || ["what is on", "what s on", "whats on"].contains(where: { ComputerText.tokens(raw).joined(separator: " ").contains($0) }) {
            return goal([GoalStep(title: language == .tr ? "Ekrandaki pencereye bakılıyor" : "Looking at the front window", actions: [
                ComputerAction(kind: .observe, target: ActionTarget(app: AppRef()), summary: "Observe the frontmost application window"),
            ])], apps: [])
        }

        // 8. switch to an application
        if let app = known, !words.isDisjoint(with: switchVerbs) {
            return goal(launchSteps(app, verb: "switch"), apps: [app])
        }

        // 9. open an application (known by name, or any installed app named exactly in the sentence)
        if !words.isDisjoint(with: openVerbs) {
            if let app = known {
                // "open the report", "open the settings" are HUD commands decided earlier; here a real application was named
                return goal(launchSteps(app, verb: "open"), apps: [app])
            }
            if let phrase = openedName(raw: raw, tokens: t), let app = AppCatalog.installed(named: phrase) { return goal(launchSteps(app, verb: "open"), apps: [app]) }
        }
        return nil
    }

    // MARK: Helpers

    private static func settingsPane(in t: [String], words: Set<String>) -> SettingsPane? {
        if words.contains("accessibility") || words.contains("erisilebilirlik") { return .accessibility }
        if words.contains("microphone") || words.contains("mikrofon") { return .microphone }
        if words.contains("screen") && (words.contains("recording") || words.contains("capture")) || words.contains("ekran") && words.contains("kaydi") { return .screenRecording }
        if words.contains("privacy") || words.contains("gizlilik") { return .privacy }
        if words.contains("displays") || words.contains("display") && words.contains("settings") { return .displays }
        return nil
    }

    private static func referencesProject(_ t: [String]) -> Bool {
        let w = Set(t)
        return w.contains("project") || w.contains("proje") || w.contains("projeyi") || w.contains("repo") || w.contains("repository") || w.contains("jarvis") && (w.contains("folder") || w.contains("klasor") || w.contains("klasoru")) || w.contains("folder") && (w.contains("project") || w.contains("proje"))
    }

    /// An absolute path or ~/path written in the sentence (quoted or bare).
    static func explicitPath(in raw: String) -> String? {
        for token in raw.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let s = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.,;()"))
            if s.hasPrefix("/") && s.count > 1 || s.hasPrefix("~/") { return s.hasPrefix("~/") ? NSHomeDirectory() + String(s.dropFirst(1)) : s }
        }
        return nil
    }

    /// The best document to hand to Xcode: an .xcworkspace, .xcodeproj, or Package.swift (opening a SwiftPM folder works too).
    static func bestProjectDocument(under root: String) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        if let w = items.first(where: { $0.hasSuffix(".xcworkspace") }) { return root + "/" + w }
        if let p = items.first(where: { $0.hasSuffix(".xcodeproj") }) { return root + "/" + p }
        if items.contains("Package.swift") { return root + "/Package.swift" }
        return nil
    }

    private static let roleWords: [String: String] = ["button": "button", "dugme": "button", "dugmesi": "button", "tab": "tab", "sekme": "tab", "sekmesi": "tab", "checkbox": "checkbox", "menu": "menuItem", "item": "menuItem", "row": "row", "link": "link", "field": "textField", "sidebar": "row"]
    private static func controlRole(_ t: [String]) -> String? { t.compactMap { roleWords[$0] }.first }

    /// The label after a click verb: a quoted string wins; otherwise the words up to a role word / "in <app>".
    private static func controlLabel(raw: String, tokens: [String], appRange: Range<Int>?) -> String? {
        if let q = quoted(raw) { return q }
        guard let verbIdx = tokens.firstIndex(where: { clickVerbs.contains($0) }) else { return nil }
        let stop: Set<String> = ["button", "tab", "dugme", "dugmesi", "sekme", "sekmesi", "in", "on", "inside", "of", "icinde", "da", "de", "menu", "item", "row", "link", "checkbox", "the", "a", "an", "to", "named", "called", "labelled", "labeled", "on"]
        var out: [String] = []
        for (i, tok) in tokens.enumerated() where i > verbIdx {
            if let r = appRange, r.contains(i) { break }
            if stop.contains(tok) { if out.isEmpty { continue } else { break } }
            out.append(tok)
            if out.count == 4 { break }
        }
        guard !out.isEmpty else { return nil }
        // recover the original capitalisation from the raw text
        let joined = out.joined(separator: " ")
        return originalCase(of: joined, in: raw) ?? joined
    }

    private static func originalCase(of folded: String, in raw: String) -> String? {
        let words = folded.split(separator: " ").map(String.init)
        let rawWords = raw.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.,;:!?()")) }
        for start in 0..<max(0, rawWords.count - words.count + 1) {
            if (0..<words.count).allSatisfy({ ComputerText.fold(rawWords[start + $0]) == words[$0] }) { return rawWords[start..<(start + words.count)].joined(separator: " ") }
        }
        return nil
    }

    private static func quoted(_ s: String) -> String? {
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")] {
            if let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex), a.upperBound < b.lowerBound {
                let inner = String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty, inner.count <= 60 { return inner }
            }
        }
        return nil
    }

    private static func openedName(raw: String, tokens: [String]) -> String? {
        guard let i = tokens.firstIndex(where: { openVerbs.contains($0) }) else { return nil }
        let tail = tokens[(i + 1)...].filter { !["the", "app", "application", "uygulamasini", "uygulamasi", "for", "me"].contains($0) }
        guard (1...3).contains(tail.count) else { return nil }
        return tail.joined(separator: " ")
    }
}
