import SwiftUI

// MARK: - Experiments & visual evidence (V0.13): what was tested in a disposable environment, what it showed, and whether the environment is gone.
// Read from the repository when the card appears and when a task finishes — never on a timer. Facts keep their class (TESTED / INFERRED / UNKNOWN …); nothing here is a model's opinion about taste.

struct ExperimentsCard: View {
    @Environment(AppContext.self) private var app
    let experiments: [ExperimentRecord]
    let observations: [VisualObservationRecord]

    var body: some View {
        Group {
            if !experiments.isEmpty || (app.preferences.showDeveloperControls && !observations.isEmpty) {
                HUDCard("Experiments", trailing: { if !experiments.isEmpty { Text("\(experiments.count) recent").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) } }) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        ForEach(experiments.prefix(4)) { row($0) }
                        if app.preferences.showDeveloperControls, !observations.isEmpty { visual }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func verdictColor(_ r: ExperimentRecord) -> Color {
        switch r.result?.verdict {
        case .confirmed?: Theme.Palette.mint
        case .refuted?: Theme.Palette.coral
        default: Theme.Palette.amber
        }
    }

    @ViewBuilder private func row(_ e: ExperimentRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Spacing.s) {
                Text(e.spec.kind.label).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary)
                Tag(text: (e.result?.verdict.rawValue ?? e.status).uppercased(), tint: verdictColor(e))
                Spacer(minLength: 0)
                Text(e.cleanupState == "deleted" ? "environment deleted" : "cleanup \(e.cleanupState)").font(.system(size: 10, design: .monospaced)).foregroundStyle(e.cleanupState == "deleted" ? Color.jarvisTertiary : Theme.Palette.amber)
            }
            Text(e.spec.question).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(2)
            if let r = e.result {
                Text(r.summary).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(3)
                let tested = r.facts.filter { $0.factClass == .tested }.count, inferred = r.facts.filter { $0.factClass == .inferred || $0.factClass == .unknown }.count
                Text("\(tested) tested fact\(tested == 1 ? "" : "s") · \(inferred) inferred / unknown · \(r.projectUntouched ? "your project untouched" : "PROJECT CHANGED") · \(Int(r.seconds)) s")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var visual: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("VISUAL EVIDENCE (hash · provider · outcome — never the picture)").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
            ForEach(observations) { o in
                Text("\(o.pictureHash.prefix(8)) · \(o.provider) · \(o.outcome)\(o.injectionNotes > 0 ? " · \(o.injectionNotes) instruction-like text(s) ignored" : "")")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary).lineLimit(1)
            }
        }
    }
}
