import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// `Jarvis --permission-report <file>`: a headless one-shot that writes what macOS says about THIS exact bundle (V1.0 stabilisation fix 3).
/// It reads permission state only — it asks for nothing, changes nothing and shows no prompt (no `AXIsProcessTrustedWithOptions` prompt option, no `CGRequestScreenCaptureAccess`).
/// Launch it through Launch Services (`open -n -a /Applications/JARVIS.app --args --permission-report /tmp/x.json`) so macOS attributes it to the bundle, as for the real app.
/// The report is also how an installed copy proves which signature identity it has (an ad-hoc cdhash changes with every build).
enum PermissionReport {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--permission-report"), i + 1 < args.count else { return }
        let out = args[i + 1]
        let report = collect()
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: out)) }
        exit(0)
    }

    static func collect() -> [String: Any] {
        var r: [String: Any] = [:]
        r["pid"] = ProcessInfo.processInfo.processIdentifier
        r["ppid"] = getppid()
        r["bundlePath"] = Bundle.main.bundlePath
        r["bundleID"] = Bundle.main.bundleIdentifier ?? "-"
        r["executable"] = Bundle.main.executablePath ?? "-"
        r["accessibilityTrusted"] = AXIsProcessTrusted()
        r["screenCapturePreflight"] = CGPreflightScreenCaptureAccess()
        r["microphone"] = "\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)"       // 0 notDetermined · 1 restricted · 2 denied · 3 authorized
        if let id = CodeIdentity.current() { r["adHoc"] = id.adHoc; r["cdhashShort"] = id.shortHash; r["canonicalInstall"] = id.isCanonicalInstall }
        if let id = CodeIdentity.current() {
            r["signingIdentifier"] = id.signingIdentifier; r["teamIdentifier"] = id.teamID ?? "none"; r["cdhash"] = id.cdhash
        }
        return r
    }
}
