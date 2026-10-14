import Foundation

// MARK: - README evidence (V0.14, DEC-224): keyword evidence from a candidate's README. README text is DATA — it is never followed; instruction-shaped passages are only counted.

enum MCPReadme {
    /// README text is DATA. Only keyword evidence is extracted; the text is never followed, and instruction-shaped passages are counted.
    static func apply(readme text: String, to r: inout MCPDiscoveryRecord) {
        let t = MemoryText.fold(text)
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["no api key", "no credentials", "no account", "without an api key", "no token"]) { r.credentialRequirement = "none stated" }
        else if has(["api key", "api_key", "apikey", "access token", "api token"]) { r.credentialRequirement = "api key" }
        else if has(["oauth", "sign in", "log in to", "login required", "account required"]) { r.credentialRequirement = "account / login" }
        if has(["execute_blender_code", "execute arbitrary", "run python code", "arbitrary code", "execute_python", "run shell", "execute shell", "exec_command"]) { r.knownRisks.append("offers arbitrary code or shell execution"); r.processRequirement = "runs code" }
        if has(["download", "internet connection", "requires internet", "api.openai", "hosted", "cloud"]) && r.networkRequirement == "unknown" { r.networkRequirement = "likely required (README mentions network use)" }
        if has(["npx ", "npm install"]) { r.installMethod = r.installMethod ?? "npm"; r.runtime = r.runtime ?? "node" }
        if has(["uvx ", "pip install", "uv pip", "pipx "]) { r.installMethod = r.installMethod ?? "pip/uv"; r.runtime = r.runtime ?? "python" }
        if has(["docker run", "docker pull"]) { r.installMethod = r.installMethod ?? "docker" }
        if has(["macos", "mac os", "apple silicon", "darwin"]) { r.macOS = "mentioned in the README" }
        if has(["windows only", "windows-only"]) { r.macOS = "no (Windows only, per README)" }
        if !UntrustedContent.scan(text).isEmpty { r.knownRisks.append("the README contains instruction-shaped text (kept as data)") }
        // tools the README names (tool-looking identifiers in a bullet list)
        let tools = text.split(separator: "\n").compactMap { line -> String? in
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("-") || line.trimmingCharacters(in: .whitespaces).hasPrefix("*") else { return nil }
            guard let range = line.range(of: "`[a-z][a-z0-9_]{3,40}`", options: .regularExpression) else { return nil }
            return String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
        r.declaredTools = Array(NSOrderedSet(array: tools).array as? [String] ?? []).prefix(12).map { $0 }
    }
}
