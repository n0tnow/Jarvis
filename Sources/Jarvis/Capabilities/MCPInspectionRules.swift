import Foundation

// MARK: - The detection patterns of the MCP source scanner (V0.14, DEC-227)
//
// This file holds ONLY the table of things the scanner looks for in a candidate's source. It must contain the very words it detects (shell, credential and Keychain access, cookies,
// SSH, persistence…), so it is the one narrowly exempted file in the `verify.sh` guards that forbid those words elsewhere.

extension MCPInspector {
    struct Rule { var category: String; var severity: MCPSecurityFinding.Severity; var detail: String; var pattern: NSRegularExpression }

    private static func rule(_ c: String, _ s: MCPSecurityFinding.Severity, _ d: String, _ p: String) -> Rule {
        Rule(category: c, severity: s, detail: d, pattern: try! NSRegularExpression(pattern: p, options: [.caseInsensitive]))
    }

    static let rules: [Rule] = [
        rule("shell", .high, "runs shell commands or child processes", "\\b(child_process|subprocess\\.(run|Popen|call|check_output)|os\\.system|os\\.popen|Runtime\\.getRuntime\\(\\)\\.exec|execSync|spawnSync|shell\\s*=\\s*True|/bin/(ba|z)?sh\\b)"),
        rule("shell", .warning, "spawns processes", "\\b(spawn|execFile|fork)\\s*\\(|std::process::Command|Command::new\\("),
        rule("network-code", .warning, "contains network client code", "\\b(reqwest|ureq|hyper::|TcpStream|UdpSocket|std::net::|requests\\.(get|post)|urllib\\.request|http\\.client|axios|node-fetch|XMLHttpRequest|URLSession)\\b"),
        rule("credentials", .high, "reads credentials or token-shaped environment values", "\\b(API_KEY|APIKEY|SECRET_KEY|ACCESS_TOKEN|AUTH_TOKEN|GITHUB_TOKEN|AWS_SECRET|PRIVATE_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY)\\b"),
        rule("environment", .warning, "enumerates or reads the whole environment", "\\b(process\\.env\\b(?!\\.[A-Z_]+\\b)|os\\.environ(\\.items|\\.copy|\\.keys)?\\b|printenv|environ\\(\\))"),
        rule("keychain", .high, "touches the macOS Keychain", "\\b(SecKeychain|SecItemCopyMatching|find-generic-password|find-internet-password|Keychain|keychain-?access|\\bsecurity\\s+(find|dump|export))"),
        rule("cookies", .high, "reads browser cookies or saved logins", "(Cookies\\.binarycookies|cookies\\.sqlite|Login Data|Local State|document\\.cookie|browser_cookie|chrome.{0,20}cookies|Safari/.*Cookies)"),
        rule("ssh", .high, "touches SSH keys or the agent", "(\\.ssh\\b|id_rsa|id_ed25519|SSH_AUTH_SOCK|known_hosts)"),
        rule("filesystem-scope", .warning, "reaches the home directory or arbitrary absolute paths", "(os\\.homedir\\(|expanduser\\(|Path\\.home\\(|NSHomeDirectory|\"~/|'~/|process\\.env\\.HOME|\\bos\\.path\\.expanduser)"),
        rule("destructive", .high, "deletes recursively or wipes", "\\b(rm\\s+-rf|rmtree|fs\\.rm(Sync)?\\([^)]*recursive|rimraf|shutil\\.rmtree|unlinkSync|os\\.remove\\(|os\\.rmdir|removeItem)"),
        rule("telemetry", .warning, "sends usage telemetry", "\\b(telemetry|posthog|mixpanel|segment\\.io|sentry\\.io|@sentry|google-analytics|datadoghq|appinsights)\\b"),
        rule("auto-update", .warning, "updates itself or installs packages at run time", "(self[-_ ]?update|auto[-_ ]?update|npm\\s+(i|install)\\s+-g|pip\\s+install|uv\\s+pip\\s+install|brew\\s+install|npx\\s+-y|checkForUpdates)"),
        rule("download-on-run", .high, "downloads and runs code", "(curl[^|\\n]*\\|\\s*(ba)?sh|wget[^|\\n]*\\|\\s*(ba)?sh|urlretrieve|\\bcurl\\s+-[a-zA-Z]*[sS]?[lL]?[oO]\\b|download.{0,30}(exec|chmod\\s+\\+x))"),
        rule("dynamic-code", .high, "evaluates dynamic code", "\\b(eval\\s*\\(|new\\s+Function\\s*\\(|exec\\s*\\(\\s*compile|__import__\\s*\\(|importlib\\.import_module|vm\\.runIn|Function\\s*\\(\\s*['\"]return)"),
        rule("persistence", .high, "installs persistence (launch agents, cron, shell profiles, login items)", "(LaunchAgents|LaunchDaemons|launchctl|crontab|\\.zshrc|\\.bash_profile|\\.bashrc|SMAppService|loginitems|osascript)"),
        rule("remote-code", .high, "loads code from the network", "(import\\s*\\(\\s*['\"]https?://|require\\(\\s*['\"]https?://|pip\\s+install\\s+git\\+|eval\\s*\\(\\s*(await\\s+)?fetch|exec\\s*\\(\\s*requests\\.get)")
    ]
}
