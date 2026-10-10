import SwiftUI

/// One segment per task step — progress is exactly "which steps are done", never a made-up percentage.
/// Segment *fill pattern* (solid / half / hollow / dashed) differs per status, not only colour.
struct SegmentedProgress: View {
    let steps: [TaskStep]
    var height: CGFloat = 6

    var body: some View {
        HStack(spacing: 3) {
            ForEach(steps) { step in
                segment(for: step.status)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Task progress")
        .accessibilityValue(summary)
    }

    private var summary: String {
        let done = steps.filter { $0.status == .completed }.count
        let active = steps.first { $0.status == .active }
        return "\(done) of \(steps.count) steps complete" + (active.map { ". Current step: \($0.title)" } ?? "")
    }

    @ViewBuilder
    private func segment(for status: StepStatus) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        switch status {
        case .completed:
            shape.fill(status.tint)
        case .active:
            shape.fill(Color.white.opacity(0.14))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        shape.fill(status.tint).frame(width: geo.size.width * 0.5)
                    }
                }
                .overlay(shape.strokeBorder(status.tint, lineWidth: 1))
        case .pending:
            shape.strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
        case .failed:
            shape.strokeBorder(status.tint, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
        }
    }
}
