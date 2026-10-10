import AppKit

/// Posts a VoiceOver announcement (no-op for sighted users). Used for events that otherwise appear silently:
/// new JARVIS replies and approval requests.
enum Announcer {
    @MainActor
    static func announce(_ text: String, high: Bool = false) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text,
                       .priority: (high ? NSAccessibilityPriorityLevel.high : NSAccessibilityPriorityLevel.medium).rawValue]
        )
    }
}
