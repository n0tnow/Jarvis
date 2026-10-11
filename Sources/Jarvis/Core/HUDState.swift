import Foundation
import Observation

/// Views the Full HUD can show. `report` is the navigation target for the future
/// "Jarvis, give me the report" flow: `windows.showFullHUD(section: .report)`.
enum HUDSection: String, CaseIterable, Identifiable, Sendable {
    case dashboard, tasks, agents, report, system, memory

    var id: String { rawValue }

    var title: String { rawValue.uppercased() }

    var symbolName: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .tasks: "checklist"
        case .agents: "person.2.wave.2"
        case .report: "doc.text"
        case .system: "cpu"
        case .memory: "externaldrive"
        }
    }
}

/// UI-only state: which HUD surfaces are on screen and where the Full HUD is navigated.
/// Kept separate from `JarvisStore` so closing windows never touches task/application state.
@MainActor
@Observable
final class HUDState {
    var section: HUDSection = .dashboard

    /// Set by `WindowManager`. Animations key off these so nothing renders while hidden.
    var isCompactVisible = false
    var isFullHUDVisible = false
}
