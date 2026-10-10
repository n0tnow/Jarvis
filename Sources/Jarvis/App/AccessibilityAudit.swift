import AppKit

/// Dev tool: walks a window's accessibility tree IN-PROCESS (no Accessibility permission involved)
/// and reports interactive elements that lack a label. Used by `--smoke-test`.
@MainActor
enum AccessibilityAudit {
    struct Item { let role: String; let label: String; let identifier: String }

    static func interactiveElements(in window: NSWindow) -> [Item] {
        var items: [Item] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let obj = element as? NSAccessibilityProtocol {
                let role = obj.accessibilityRole()?.rawValue ?? ""
                if ["AXButton", "AXTextField", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton"].contains(role) {
                    let label: String? = obj.accessibilityLabel()
                    let title: String? = obj.accessibilityTitle()
                    let identifier: String? = obj.accessibilityIdentifier()
                    items.append(Item(role: role, label: label ?? title ?? "", identifier: identifier ?? ""))
                }
                for child in obj.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
            }
        }
        if let content = window.contentView { visit(content, depth: 0) }
        return items
    }
}
