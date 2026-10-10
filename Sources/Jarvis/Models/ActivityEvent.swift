import Foundation

enum ActivityKind: String, Codable, Sendable {
    case info, success, warning, error, command, system

    var symbolName: String {
        switch self {
        case .info: "circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .command: "chevron.right"
        case .system: "gearshape.fill"
        }
    }

    var label: String {
        switch self {
        case .info: "Info"
        case .success: "Success"
        case .warning: "Warning"
        case .error: "Error"
        case .command: "Command"
        case .system: "System"
        }
    }
}

struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var timestamp: Date
    var message: String
    var kind: ActivityKind = .info
}
