import Foundation

// MARK: - About / Diagnostics (V0.15)
//
// A short, SANITISED text a person can paste into a bug report: versions, system, and each readiness item's NAME and STATE. It contains no paths, no account names, no credentials, no
// transcripts, no audio, no screenshots and no project content.

enum DiagnosticsReport {
    static func hardware() -> String {
        var size = 0; sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    static func build(snapshot: ReadinessSnapshot, schema: Int?, installed: Bool, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("JARVIS \(AppInfo.versionLine) (\(AppInfo.milestone)) · \(installed ? "installed application" : "development build")")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(hardware())")
        lines.append("Database schema: \(schema.map { "v\($0)" } ?? "unavailable")")
        lines.append("Readiness: \(snapshot.summary.headline)")
        for cat in ReadinessCategory.allCases {
            let items = snapshot.items(in: cat)
            guard !items.isEmpty else { continue }
            lines.append("\(cat.rawValue): " + items.map { "\($0.name) — \($0.state.label)" }.joined(separator: "; "))
        }
        return OutputSanitizer.sanitize(lines.joined(separator: "\n"))
    }
}
