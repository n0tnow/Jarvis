import Foundation

// MARK: - V0.11 policy: what an action MEANS decides what it may do (DEC-127…)
//
// Pure and exhaustively unit-tested. Risk comes from the semantic CONSEQUENCE of an action ("OK" may save, delete, buy or send), never from the
// control type. Text found in the UI is untrusted data: it may RAISE the risk of a generic button (a confirm button in a dialog about deleting),
// it can never lower it, never grant anything and never change a rule.

enum ComputerText {
    /// Lowercase, diacritics and apostrophes removed, dotless ı folded — the same folding the rest of JARVIS uses for matching.
    static func fold(_ s: String) -> String {
        var f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        for q in ["'", "’", "‘", "ʼ", "`"] { f = f.replacingOccurrences(of: q, with: "") }
        return f
    }
    static func tokens(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
    }
    /// Menu titles end in "…"/"..." — never part of the meaning.
    static func menuKey(_ s: String) -> String {
        fold(s).replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Consequences

enum Consequence: String, Codable, Sendable {
    case purchase, accountAction, credentialEntry, install, privacyGrant, securityChange, sendMessage, publish, forceQuit, commandExecution, quarantinedOpen
    case delete, overwrite, submitForm, quit, privacyDeny
    case save, closeWindow, changeSetting
    case genericConfirm
    case ordinary

    var blockedForever: Bool {
        switch self {
        case .purchase, .accountAction, .credentialEntry, .install, .privacyGrant, .securityChange, .sendMessage, .publish, .forceQuit, .commandExecution, .quarantinedOpen: true
        default: false
        }
    }
    var risk: RiskClass {
        switch self {
        case .purchase, .accountAction, .credentialEntry, .install, .privacyGrant, .securityChange, .sendMessage, .publish, .forceQuit, .commandExecution, .quarantinedOpen: .critical
        case .delete, .overwrite, .submitForm, .quit: .high
        case .save, .closeWindow, .changeSetting, .privacyDeny, .genericConfirm: .medium
        case .ordinary: .low
        }
    }
    var label: String {
        switch self {
        case .purchase: "a purchase"; case .accountAction: "an account action"; case .credentialEntry: "credential entry"; case .install: "an installation"
        case .privacyGrant: "granting a permission"; case .securityChange: "a security/system setting"; case .sendMessage: "sending a message"; case .publish: "publishing/deploying"
        case .forceQuit: "force-quitting"; case .commandExecution: "running a command"; case .quarantinedOpen: "opening a quarantined/executable file"
        case .delete: "deleting"; case .overwrite: "overwriting"; case .submitForm: "submitting a form"; case .quit: "quitting an application"; case .privacyDeny: "changing a permission"
        case .save: "saving"; case .closeWindow: "closing a window"; case .changeSetting: "changing a setting"; case .genericConfirm: "confirming a dialog"; case .ordinary: "an ordinary action"
        }
    }
}

enum ConsequenceClassifier {
    private static let purchase: Set<String> = ["buy", "purchase", "pay", "checkout", "subscribe", "subscription", "order", "satin", "ode", "odeme", "siparis", "abone", "upgrade"]
    private static let purchasePhrases = ["place order", "check out", "buy now", "add payment", "satin al", "get premium", "start trial", "free trial", "unlock full"]
    private static let account: Set<String> = ["login", "signin", "signup", "register", "authorize", "authorise", "agree", "accept", "kabul", "onayla", "giris", "kayit"]
    private static let accountPhrases = ["sign in", "sign up", "log in", "create account", "accept terms", "i agree", "add account", "add to account", "oturum ac", "giris yap", "kayit ol", "kabul et", "terms of service", "continue with apple", "continue with google"]
    private static let credential: Set<String> = ["password", "passcode", "passphrase", "keychain", "token", "sifre", "parola", "credentials", "otp"]
    private static let credentialPhrases = ["api key", "secret key", "private key", "touch id", "use password", "enter password", "recovery key"]
    private static let install: Set<String> = ["install", "installer", "setup", "kur", "yukle", "uninstall"]
    private static let installPhrases = ["update now", "install now", "run installer", "software update", "install update"]
    private static let privacyGrant: Set<String> = ["allow", "grant", "izin"]
    private static let privacyGrantPhrases = ["full disk access", "allow access", "give access", "izin ver", "always allow", "allow once"]
    private static let privacyDenyPhrases = ["dont allow", "do not allow", "izin verme", "deny"]
    private static let security: Set<String> = ["gatekeeper", "filevault", "firewall", "sip", "lockdown"]
    private static let securityPhrases = ["system integrity", "privacy and security", "disable security", "turn off firewall", "security settings", "login items", "profiles"]
    private static let send: Set<String> = ["send", "gonder", "yolla", "tweet", "reply", "post", "paylas", "share", "email", "mail"]
    private static let sendPhrases = ["send message", "send email", "send now", "mesaj gonder", "post comment", "reply all"]
    private static let publish: Set<String> = ["publish", "deploy", "push", "release", "yayinla"]
    private static let publishPhrases = ["go live", "make public", "git push", "force push"]
    private static let forceQuit: Set<String> = ["forcequit"]
    private static let forceQuitPhrases = ["force quit", "kill process", "zorla kapat", "quit anyway", "terminate"]
    private static let delete: Set<String> = ["delete", "erase", "remove", "trash", "discard", "wipe", "format", "reset", "purge", "destroy", "sil", "kaldir", "temizle", "clear"]
    private static let deletePhrases = ["move to trash", "empty trash", "delete all", "delete immediately", "dont save", "do not save", "kaydetme", "clear all", "erase all", "cop kutusu", "remove all"]
    private static let overwrite: Set<String> = ["overwrite", "replace", "uzerine"]
    private static let overwritePhrases = ["replace all", "uzerine yaz"]
    private static let submit: Set<String> = ["submit", "gonder"]
    private static let submitPhrases = ["apply changes", "confirm order"]
    private static let quit: Set<String> = ["quit", "exit", "cik"]
    private static let save: Set<String> = ["save", "export", "kaydet", "saveas"]
    private static let close: Set<String> = ["close", "kapat"]
    private static let setting: Set<String> = ["enable", "disable", "toggle", "turn"]
    private static let generic: Set<String> = ["ok", "okay", "confirm", "continue", "yes", "done", "apply", "next", "proceed", "evet", "tamam", "devam", "sure", "got", "default", "allow"]
    private static let benign: Set<String> = ["cancel", "no", "later", "not", "now", "hayir", "iptal", "vazgec", "dismiss", "back", "close", "skip", "thanks", "maybe"]
    private static let priceRegex = try! NSRegularExpression(pattern: #"([$€£₺¥]\s?\d)|(\d[\d.,]*\s?(usd|eur|gbp|try|tl|dollars?|euros?|lira))"#, options: [.caseInsensitive])

    private static func hit(_ tokens: [String], _ folded: String, words: Set<String>, phrases: [String]) -> Bool {
        tokens.contains { words.contains($0) } || phrases.contains { folded.contains($0) }
    }

    /// The consequence of the control's OWN label (no context).
    static func classify(label: String) -> Consequence {
        let f = ComputerText.fold(label), t = ComputerText.tokens(label)
        if t.isEmpty { return .ordinary }
        if priceRegex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil { return .purchase }
        // Order = severity. A permission DENIAL is checked before "allow" (it contains the word).
        if forceQuitPhrases.contains(where: f.contains) || t.contains(where: forceQuit.contains) { return .forceQuit }
        if hit(t, f, words: purchase, phrases: purchasePhrases) { return .purchase }
        if hit(t, f, words: credential, phrases: credentialPhrases) { return .credentialEntry }
        if privacyDenyPhrases.contains(where: f.contains) { return .privacyDeny }
        if hit(t, f, words: account, phrases: accountPhrases) { return .accountAction }
        if hit(t, f, words: install, phrases: installPhrases) { return .install }
        if hit(t, f, words: privacyGrant, phrases: privacyGrantPhrases) { return .privacyGrant }
        if hit(t, f, words: security, phrases: securityPhrases) { return .securityChange }
        if hit(t, f, words: publish, phrases: publishPhrases) { return .publish }
        if hit(t, f, words: send, phrases: sendPhrases) { return .sendMessage }
        if hit(t, f, words: delete, phrases: deletePhrases) { return .delete }
        if hit(t, f, words: overwrite, phrases: overwritePhrases) { return .overwrite }
        if hit(t, f, words: submit, phrases: submitPhrases) { return .submitForm }
        if t.contains(where: quit.contains) { return .quit }
        if t.contains(where: save.contains) { return .save }
        if t.contains(where: setting.contains) { return .changeSetting }
        if t.contains(where: close.contains) { return .closeWindow }
        if t.allSatisfy({ generic.contains($0) }) { return .genericConfirm }
        return .ordinary
    }

    /// Is this a plain "never mind" control? (Cancel in a dangerous dialog is always safe.)
    static func isBenign(label: String) -> Bool {
        let t = ComputerText.tokens(label)
        return !t.isEmpty && t.allSatisfy { benign.contains($0) } && !ComputerText.fold(label).contains("dont save")
    }

    /// With context (the visible text of the dialog the control sits in). Context can only RAISE: a generic confirm button inherits what the dialog says.
    static func classify(label: String, context: [String]) -> Consequence {
        let own = classify(label: label)
        if isBenign(label: label) { return .ordinary }
        // Only a generic confirm ("OK", "Continue", "Yes") has no meaning of its own, so only it inherits the dialog's meaning. A control with a meaning of its
        // own keeps it: "Run" in a window whose title says "Buy" is still just Run (and a title is untrusted text anyway).
        guard own == .genericConfirm else { return own }
        var worst = own
        for c in context.prefix(12) {
            let k = classify(label: String(c.prefix(240)))
            if k == .genericConfirm || k == .ordinary || k == .closeWindow || k == .changeSetting { continue }
            if k.risk > worst.risk || (k.risk == worst.risk && k.blockedForever && !worst.blockedForever) { worst = k }
        }
        return worst
    }
}

// MARK: Text entry

enum TextPolicy {
    static func classify(_ text: String) -> TextClass {
        if text.isEmpty { return .plain }
        if OutputSanitizer.containsSecret(text) || looksLikePassword(text) { return .sensitive }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("://") || t.hasPrefix("www.") { return .url }
        if t.hasPrefix("/") || t.hasPrefix("~/") { return .pathLike }
        if looksLikeCommand(t) { return .commandLike }
        return .plain
    }

    /// A single token with no spaces that mixes character classes — what a password looks like. (A word, a path or a sentence is not.)
    static func looksLikePassword(_ s: String) -> Bool {
        guard (8...72).contains(s.count), !s.contains(" "), !s.contains("/"), !s.contains(".") || s.filter({ $0 == "." }).count < 2 else { return false }
        let upper = s.contains { $0.isUppercase }, lower = s.contains { $0.isLowercase }, digit = s.contains { $0.isNumber }
        let symbol = s.contains { !$0.isLetter && !$0.isNumber }
        return [upper, lower, digit, symbol].filter { $0 }.count >= 3
    }

    private static let commandStarts = ["sudo ", "rm ", "rm -", "curl ", "wget ", "git push", "git reset", "git clean", "chmod ", "chown ", "dd ", "mkfs", "osascript", "launchctl", "defaults write", "killall", "kill -", "ssh ", "scp ", "nc ", "python -c", "python3 -c", "bash -c", "sh -c", "open -a", "brew install", "pip install", "npm install", "npm publish"]
    static func looksLikeCommand(_ s: String) -> Bool {
        let f = s.lowercased()
        if commandStarts.contains(where: f.hasPrefix) { return true }
        return f.contains("&&") || f.contains("; rm ") || f.contains("| sh") || f.contains("|sh") || f.contains("$(") || f.contains("`")
    }
}

// MARK: Shortcuts

enum ShortcutClass: Equatable, Sendable {
    case allowed(RiskClass)
    case needsApproval(String)
    case blocked(String)
    case unknown
}

enum ShortcutPolicy {
    private static let cmd: Set<ChordModifier> = [.command]
    private static let cmdShift: Set<ChordModifier> = [.command, .shift]
    /// Allowlist. Anything not listed is UNKNOWN and never executes automatically (spec §31).
    private static let table: [KeyChord: RiskClass] = {
        var t: [KeyChord: RiskClass] = [:]
        for k in ["f", "a", "c", "z", "t", "n", "o", "l", "comma", "left_bracket", "right_bracket", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "j", "e"] { t[KeyChord(k, cmd)] = .low }
        for k in ["z", "o", "f", "j", "l"] { t[KeyChord(k, cmdShift)] = .low }
        t[KeyChord("s", cmd)] = .medium
        t[KeyChord("s", cmdShift)] = .medium
        t[KeyChord("w", cmd)] = .medium
        for k in ["escape", "tab", "up", "down", "left", "right", "space", "home", "end", "pageup", "pagedown"] { t[KeyChord(k)] = .low }
        t[KeyChord("tab", [.shift])] = .low
        t[KeyChord("return")] = .medium          // see `isDefaultButtonKey`: with a dialog in front it IS a button press and is judged as one
        t[KeyChord("enter")] = .medium
        return t
    }()
    private static let hardBlocked: [KeyChord: String] = [
        KeyChord("escape", [.command, .option]): "force-quit panel",
        KeyChord("q", [.command, .control]): "lock screen",
        KeyChord("delete", [.command, .shift]): "empty Trash",
        KeyChord("space", cmd): "Spotlight (a command launcher)",
        KeyChord("space", [.command, .option]): "Spotlight (a command launcher)",
        KeyChord("q", [.command, .shift]): "log out",
        KeyChord("q", [.command, .shift, .option]): "log out immediately",
        KeyChord("power", []): "power key",
    ]
    private static let approval: [KeyChord: String] = [
        KeyChord("q", cmd): "quit the application",
        KeyChord("delete", cmd): "delete the selection",
        KeyChord("backspace", cmd): "delete the selection",
    ]
    static func classify(_ c: KeyChord) -> ShortcutClass {
        if let why = hardBlocked[c] { return .blocked(why) }
        if let why = approval[c] { return .needsApproval(why) }
        if let r = table[c] { return .allowed(r) }
        return .unknown
    }
    static func isDefaultButtonKey(_ c: KeyChord) -> Bool { c.modifiers.isEmpty && (c.key == "return" || c.key == "enter") }
}

// MARK: Surfaces that execute commands, applications that talk to other people, credential stores

enum SurfacePolicy {
    static let terminalApps: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.shortcuts"]
    static let commsApps: Set<String> = ["com.apple.MobileSMS", "com.apple.mail", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos", "com.apple.FaceTime", "com.readdle.smartemail-Mac", "com.microsoft.Outlook"]
    static let credentialApps = ["1password", "agilebits", "bitwarden", "lastpass", "dashlane", "keychainaccess", "com.apple.passwords", "keepassxc", "enpass"]
    static let systemSettings = "com.apple.systempreferences"
    static let finder = "com.apple.finder"
    private static let consoleWords = ["terminal", "console", "shell", "repl", "immediate window", "command line", "powershell", "python console", "script editor", "devtools"]

    static func isTerminalApp(_ bundleID: String?) -> Bool { bundleID.map(terminalApps.contains) ?? false }
    static func isCommsApp(_ bundleID: String?) -> Bool { bundleID.map(commsApps.contains) ?? false }
    static func isCredentialApp(_ bundleID: String?) -> Bool {
        guard let b = bundleID?.lowercased() else { return false }
        return credentialApps.contains { b.contains($0) }
    }
    /// An element (or one of its ancestors / its window) that is a place to type COMMANDS: Terminal, an IDE terminal, a Python console, DevTools.
    static func isCommandSurface(bundleID: String?, window: String?, element: UIElementSnapshot?) -> Bool {
        if isTerminalApp(bundleID) { return true }
        let hay = ([window, element?.title, element?.help, element?.identifier, element?.subrole] + (element?.ancestorTitles.map { Optional($0) } ?? [])).compactMap { $0 }.map { ComputerText.fold($0) }
        return hay.contains { h in consoleWords.contains { h.contains($0) } }
    }
}

// MARK: Paths & files

enum ComputerPathPolicy {
    enum Verdict: Equatable, Sendable { case allowed(String), refused(String) }

    static let executableExtensions: Set<String> = ["app", "pkg", "mpkg", "dmg", "iso", "command", "tool", "sh", "zsh", "bash", "csh", "scpt", "scptd", "applescript", "workflow", "action", "jar", "exe", "msi", "bat", "cmd", "webloc", "inetloc", "fileloc", "terminal", "url", "dylib", "kext", "prefpane", "saver", "plugin", "xpc"]
    private static let protectedPrefixes = ["Library/Keychains", "Library/Cookies", "Library/Messages", "Library/Mail", "Library/Safari", "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox",
                                            "Library/Application Support/com.apple.sharedfilelist", "Library/Application Support/JARVIS", "Library/Preferences", "Library/Containers/com.apple.mail", ".config/gcloud", ".docker", ".gnupg", ".ssh", ".aws", ".kube"]

    /// `quarantineRoot` = JARVIS' acquisition quarantine (downloaded third-party artifacts). Nothing in there is opened by Computer Use.
    static func validate(_ raw: String, quarantineRoot: String?, forReveal: Bool = false, home: String = NSHomeDirectory()) -> Verdict {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_024, !trimmed.contains("\0") else { return .refused("not a usable path") }
        let expanded = trimmed.hasPrefix("~/") ? home + String(trimmed.dropFirst(1)) : trimmed
        guard expanded.hasPrefix("/") else { return .refused("the path must be absolute") }
        if expanded.split(separator: "/").contains("..") { return .refused("path traversal") }
        guard let real = Darwin.realpath(expanded, nil) else { return .refused("the file does not exist") }
        defer { free(real) }
        let path = String(cString: real)
        let comps = path.split(separator: "/").map(String.init)
        if WorkspaceGuard.isProtected(comps) { return .refused("a protected credential/secret location") }
        for p in protectedPrefixes {
            let full = home + "/" + p
            if path == full || path.hasPrefix(full + "/") { return .refused("a protected location (\(p))") }
        }
        if let q = quarantineRoot.flatMap({ Darwin.realpath($0, nil) }).map({ ptr -> String in defer { free(ptr) }; return String(cString: ptr) }), path == q || path.hasPrefix(q + "/") {
            return .refused("the V0.9 quarantine: downloaded files are never opened by Computer Use")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if !forReveal, executableExtensions.contains(ext) { return .refused("“.\(ext)” is an executable/installer type — Computer Use never opens it") }
        if !forReveal, getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0, executableExtensions.contains(ext) { return .refused("a quarantined download") }
        return .allowed(path)
    }
}

// MARK: Assessment

enum PolicyVerdict: Equatable, Sendable {
    case allow
    case needsApproval(String)
    case blocked(String, FailureCategory)
}

struct ActionAssessment: Sendable {
    var risk: RiskClass
    var consequence: Consequence
    var verdict: PolicyVerdict
    var mechanism: ComputerMechanism
    var reasons: [String]
}

struct ActionPolicyContext: Sendable {
    var bundleID: String?
    var windowTitle: String?
    var element: UIElementSnapshot?
    /// Visible texts of the dialog/window the element sits in (UNTRUSTED: can only raise risk).
    var contextTexts: [String] = []
    var modalPresent = false
    /// The default button's label when a dialog is in front (for Return/Enter).
    var defaultButtonLabel: String?
    var quarantineRoot: String?
    var home = NSHomeDirectory()
}

enum ComputerPolicy {
    /// THE policy decision for one action. Everything that can stop an action stops it here, before anything is dispatched.
    static func assess(_ a: ComputerAction, in c: ActionPolicyContext) -> ActionAssessment {
        var reasons: [String] = []
        func block(_ why: String, _ cons: Consequence, _ cat: FailureCategory = .securityBlocked) -> ActionAssessment {
            ActionAssessment(risk: cons.risk, consequence: cons, verdict: .blocked(why, cat), mechanism: mechanism(for: a), reasons: reasons + [why])
        }
        func done(_ cons: Consequence, _ verdict: PolicyVerdict, risk: RiskClass? = nil) -> ActionAssessment {
            ActionAssessment(risk: risk ?? cons.risk, consequence: cons, verdict: verdict, mechanism: mechanism(for: a), reasons: reasons)
        }

        // 0. credential stores and communication apps: observation of controls only
        if SurfacePolicy.isCredentialApp(c.bundleID), a.kind != .activateApplication, a.kind != .launchApplication {
            return block("password managers and keychains are the user's to operate; Computer Use never reads or drives them", .credentialEntry, .interactionRequired)
        }
        // 1. secure fields: no reading, no typing, no setting, no copying — ever
        if let e = c.element, e.isSecure, a.kind != .observe {
            return block("this is a secure (password) field — enter it yourself", .credentialEntry, .interactionRequired)
        }
        // 2. keystrokes and text
        if a.kind.sendsKeystrokes || a.kind == .setText {
            let text = a.text ?? ""
            let cls = TextPolicy.classify(text)
            if text.count > ComputerLimits.maxTextLength { return block("the text is longer than \(ComputerLimits.maxTextLength) characters", .ordinary) }
            if cls == .sensitive { return block("the text looks like a secret or password — Computer Use never types those", .credentialEntry, .interactionRequired) }
            if SurfacePolicy.isTerminalApp(c.bundleID) || SurfacePolicy.isCommandSurface(bundleID: c.bundleID, window: c.windowTitle, element: c.element) {
                return block("typing into a terminal/console would bypass the command policy (only approved executables run, through the task engine)", .commandExecution)
            }
            if SurfacePolicy.isCommsApp(c.bundleID) { return block("sending messages is not part of Computer Use", .sendMessage) }
            if cls == .commandLike { reasons.append("the text looks like a shell command") }
        }
        // 3. per kind
        switch a.kind {
        case .observe, .captureWindow:
            return done(.ordinary, .allow, risk: .low)
        case .launchApplication, .activateApplication, .focusWindow, .minimizeWindow, .restoreWindow:
            return done(.ordinary, .allow, risk: .low)
        case .quitApplication:
            return done(.quit, .needsApproval("Quit \(a.target.app.display)? Unsaved work in it could be lost."))
        case .closeWindow:
            return done(.closeWindow, .needsApproval("Close the window “\(a.target.windowTitle ?? "?")”? It may hold unsaved work."), risk: .medium)
        case .scroll:
            return done(.ordinary, .allow, risk: .low)
        case .openSettingsPane:
            return done(.ordinary, .allow, risk: .low)
        case .openFile, .revealFile:
            switch ComputerPathPolicy.validate(a.path ?? "", quarantineRoot: c.quarantineRoot, forReveal: a.kind == .revealFile, home: c.home) {
            case .refused(let why): return block(why, .quarantinedOpen)
            case .allowed: return done(.ordinary, .allow, risk: a.kind == .openFile ? .medium : .low)
            }
        case .typeText, .setText:
            return done(.ordinary, a.origin == .userWords ? .allow : .needsApproval("Type text (\((a.text ?? "").count) characters) into \(a.target.description)?"), risk: .medium)
        case .pressShortcut, .pressKey:
            guard let chord = a.chord else { return block("no key given", .ordinary, .malformedPlan) }
            if ShortcutPolicy.isDefaultButtonKey(chord), c.modalPresent {
                let k = ConsequenceClassifier.classify(label: c.defaultButtonLabel ?? "", context: c.contextTexts)
                if c.defaultButtonLabel == nil { return done(.genericConfirm, .needsApproval("Return would press the dialog's default button, which JARVIS cannot read."), risk: .high) }
                return consequenceVerdict(k, a, c, reasons: reasons, label: c.defaultButtonLabel ?? "default button")
            }
            switch ShortcutPolicy.classify(chord) {
            case .blocked(let why): return block("\(chord.display) is blocked (\(why))", .securityChange)
            case .needsApproval(let why): return done(.quit, .needsApproval("\(chord.display): \(why)"), risk: .high)
            case .unknown: return block("\(chord.display) is not on the shortcut allowlist, so it is not executed automatically", .ordinary)
            case .allowed(let r):
                return done(r == .medium ? .save : .ordinary, (r == .medium && a.origin == .modelProposal) ? .needsApproval("Press \(chord.display)?") : .allow, risk: r)
            }
        case .selectMenuItem:
            let leaf = a.target.menuPath.last ?? a.target.title ?? ""
            // Finder: opening/trashing through its menu would bypass the typed file tools and the quarantine rules
            if c.bundleID == SurfacePolicy.finder {
                let k = ComputerText.menuKey(leaf)
                if ["move to trash", "delete immediately", "empty trash", "secure empty trash"].contains(where: k.hasPrefix) { return block("deleting files through Finder is not allowed — deletion goes through the typed, approved delete step", .delete) }
                if k == "open" || k.hasPrefix("open with") || k == "get info" || k == "compress" || k == "duplicate" { return block("Finder menu actions on files bypass the file policy — use the typed open/reveal actions", .quarantinedOpen) }
            }
            return consequenceVerdict(ConsequenceClassifier.classify(label: leaf, context: []), a, c, reasons: reasons, label: leaf)
        case .pressElement, .visionPress:
            let label = c.element?.title.isEmpty == false ? c.element!.title : (a.target.title ?? "")
            var k = ConsequenceClassifier.classify(label: label, context: c.contextTexts + (c.element?.ancestorTitles ?? []))
            if c.bundleID == SurfacePolicy.systemSettings, let e = c.element, ["checkbox", "switch", "radiobutton", "popupbutton", "slider", "button"].contains(Self.shortRole(e.role)), !Self.isNavigation(e) {
                reasons.append("System Settings: only navigation is automatic; toggles are the user's")
                k = k.blockedForever ? k : .securityChange
            }
            if a.kind == .visionPress { reasons.append("vision-derived target") }
            return consequenceVerdict(k, a, c, reasons: reasons, label: label)
        }
    }

    private static func consequenceVerdict(_ k: Consequence, _ a: ComputerAction, _ c: ActionPolicyContext, reasons: [String], label: String) -> ActionAssessment {
        let mech = mechanism(for: a)
        if k.blockedForever {
            return ActionAssessment(risk: .critical, consequence: k, verdict: .blocked("“\(label.prefix(60))” means \(k.label) — Computer Use has no permission for that", .securityBlocked), mechanism: mech, reasons: reasons + ["consequence:\(k.rawValue)"])
        }
        switch k.risk {
        case .low:
            return ActionAssessment(risk: .low, consequence: k, verdict: .allow, mechanism: mech, reasons: reasons)
        case .medium:
            let auto = a.origin == .userWords && k != .privacyDeny
            return ActionAssessment(risk: .medium, consequence: k, verdict: auto ? .allow : .needsApproval("Press “\(label.prefix(60))” (\(k.label))?"), mechanism: mech, reasons: reasons + ["consequence:\(k.rawValue)"])
        default:
            return ActionAssessment(risk: k.risk, consequence: k, verdict: .needsApproval("Press “\(label.prefix(60))”: this means \(k.label). Approve only if you want exactly that."), mechanism: mech, reasons: reasons + ["consequence:\(k.rawValue)"])
        }
    }

    static func mechanism(for a: ComputerAction) -> ComputerMechanism {
        switch a.kind {
        case .visionPress, .captureWindow: .vision
        default: .accessibility
        }
    }

    static func shortRole(_ role: String) -> String { ComputerText.fold(role.replacingOccurrences(of: "AX", with: "")) }

    /// Rows/tabs/outline items in a sidebar are navigation; switches, checkboxes and popups are changes.
    static func isNavigation(_ e: UIElementSnapshot) -> Bool {
        ["row", "tab", "radiobutton", "outlinerow", "cell", "statictext", "tabgroup", "link", "disclosuretriangle"].contains(shortRole(e.role)) && !["checkbox", "switch", "popupbutton"].contains(shortRole(e.role))
    }

    /// Can the same action be repeated without harm? Drives the retry policy (spec §121).
    static func idempotency(of a: ComputerAction, consequence: Consequence) -> ActionIdempotency {
        switch a.kind {
        case .observe, .captureWindow, .launchApplication, .activateApplication, .focusWindow, .restoreWindow, .minimizeWindow, .scroll, .revealFile, .openSettingsPane: .safe
        case .openFile: .verifyFirst
        case .setText: .verifyFirst
        case .selectMenuItem, .pressElement, .visionPress:
            switch consequence {
            case .ordinary, .genericConfirm: .verifyFirst
            case .save: .verifyFirst
            default: .unsafe
            }
        case .pressKey, .pressShortcut: ShortcutPolicy.classify(a.chord ?? KeyChord("x")) == .allowed(.low) ? .verifyFirst : .unsafe
        case .typeText, .quitApplication, .closeWindow: .unsafe
        }
    }
}

enum ActionIdempotency: String, Codable, Sendable { case safe, verifyFirst, unsafe }
