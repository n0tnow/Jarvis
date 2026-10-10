import SwiftUI

/// The ONE canonical Compact HUD size. The window (`WindowManager`) and the SwiftUI root both use it, so
/// no state, task, or setting can ever change the outer geometry. Content changes live inside this frame.
///
/// Height budget (worst legitimate case: active task with a 2-line title and the developer strip visible)
/// is covered by `taskCardHeight` being fixed; leaving the dev strip off simply leaves bottom breathing room.
enum CompactHUDLayout {
    static let size = CGSize(width: 392, height: 448)
    static let taskCardHeight: CGFloat = 150
    /// Internal content transitions only — never the window frame.
    static let transition = 0.2
}
