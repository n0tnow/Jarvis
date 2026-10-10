import SwiftUI

/// Elapsed run time. Ticks once per second only while the task is running AND the surface is visible.
struct ElapsedText: View {
    let task: JarvisTask
    let isVisible: Bool

    var body: some View {
        if task.status == .running && isVisible {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                text(at: timeline.date)
            }
        } else {
            text(at: .now)
        }
    }

    private func text(at date: Date) -> some View {
        let seconds = task.elapsed(at: date)
        return Text(Self.format(seconds))
            .monospacedDigit()
            .accessibilityLabel("Elapsed time")
            .accessibilityValue(Self.spoken(seconds))
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func spoken(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) \(h == 1 ? "hour" : "hours")") }
        if m > 0 { parts.append("\(m) \(m == 1 ? "minute" : "minutes")") }
        parts.append("\(s) \(s == 1 ? "second" : "seconds")")
        return parts.joined(separator: " ")
    }
}
