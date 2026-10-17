import Foundation
import Observation

/// Views the Full HUD can show. `report` is the navigation target for the future
/// "Jarvis, give me the report" flow: `windows.showFullHUD(section: .report)`.
enum HUDSection: String, CaseIterable, Identifiable, Sendable {
    case dashboard, tasks, agents, research, report, system, memory, computer, learning, capabilities, settings

    var id: String { rawValue }

    var title: String { rawValue.uppercased() }

    var symbolName: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .tasks: "checklist"
        case .agents: "person.2.wave.2"
        case .research: "magnifyingglass"
        case .report: "doc.text"
        case .system: "cpu"
        case .memory: "externaldrive"
        case .computer: "cursorarrow.rays"
        case .learning: "brain.head.profile"
        case .capabilities: "puzzlepiece.extension"
        case .settings: "gearshape"
        }
    }
}

/// UI-only state: which HUD surfaces are on screen and where the Full HUD is navigated.
/// Kept separate from `JarvisStore` so closing windows never touches task/application state.
@MainActor
@Observable
final class HUDState {
    var section: HUDSection = .dashboard
    /// Which Settings category is open (the Full HUD Settings page).
    var settingsCategory: SettingsCategory = .general
    /// The task expanded in the Tasks screen (UI-only; closing the HUD never touches the task).
    var selectedTaskID: UUID?

    /// Set by `WindowManager`. Animations key off these so nothing renders while hidden.
    var isCompactVisible = false
    var isFullHUDVisible = false
}
