import Foundation
import Security

/// Which code macOS is judging when it answers "is JARVIS allowed?" (V1.0 stabilisation fix 3).
///
/// macOS ties every privacy permission (Accessibility, Screen Recording, Microphone…) to a code identity. For an AD-HOC signed app that identity is the code-directory hash of
/// THIS exact build, so every rebuild/install is, for macOS, a different app that happens to share a name and bundle identifier: a switch that was turned on for the previous build
/// stays visible in System Settings but no longer applies. With a stable signing identity the requirement is "identifier + certificate" and survives updates.
/// This type only reads the running process' own signature; it asks for nothing.
struct CodeIdentity: Equatable, Sendable {
    var bundlePath: String
    var bundleID: String
    var signingIdentifier: String
    var cdhash: String
    var adHoc: Bool
    var teamID: String?

    var shortHash: String { String(cdhash.prefix(8)) }
    var isCanonicalInstall: Bool { bundlePath == "/Applications/JARVIS.app" }

    static func current() -> CodeIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?                  // flag 2 = "signing information"
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 2), &info) == errSecSuccess, let d = info as? [String: Any] else { return nil }
        let hash = (d["unique"] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
        let team = d["teamid"] as? String
        let flags = (d["flags"] as? UInt32) ?? 0
        let adhoc = flags & 0x2 != 0 || (team == nil && (d["certificates"] as? [Any])?.isEmpty != false)
        return CodeIdentity(bundlePath: Bundle.main.bundlePath, bundleID: Bundle.main.bundleIdentifier ?? "-", signingIdentifier: (d["identifier"] as? String) ?? "-", cdhash: hash, adHoc: adhoc, teamID: team)
    }
}
