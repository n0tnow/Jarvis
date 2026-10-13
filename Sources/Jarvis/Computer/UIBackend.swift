import Foundation
import CoreGraphics

// MARK: - The seam between Computer Use logic and macOS
//
// Everything the executor needs from the system goes through this protocol. The real implementation is `AXBackend` (the ONLY file that talks to AXUIElement /
// CGEvent); automated tests use a fake backend with a virtual application, so policy, resolution, verification, retries and cancellation are tested without a GUI.

enum BackendError: Error, Equatable, CustomStringConvertible {
    case permissionDenied
    case appNotFound(String)
    case launchFailed(String)
    case noWindow
    case elementGone
    case actionFailed(String)
    case unsupported(String)
    case timedOut
    case secureField
    case captureUnavailable(String)

    var description: String {
        switch self {
        case .permissionDenied: "Accessibility permission is not granted"
        case .appNotFound(let a): "application not found: \(a)"
        case .launchFailed(let w): "the application did not launch: \(w)"
        case .noWindow: "the application has no window"
        case .elementGone: "the element is gone"
        case .actionFailed(let w): "the action failed: \(w)"
        case .unsupported(let w): "not supported: \(w)"
        case .timedOut: "the application did not respond in time"
        case .secureField: "secure field"
        case .captureUnavailable(let w): "screen capture unavailable: \(w)"
        }
    }
}

enum ElementOp: String, Sendable { case press, confirm, showMenu, raise, increment, decrement, cancel, scrollToVisible, focus, select }
enum WindowOp: String, Sendable { case raise, minimize, restore, close }

struct AXBudget: Sendable {
    var maxNodes = ComputerLimits.maxTreeNodes
    var maxDepth = ComputerLimits.maxTreeDepth
    var timeBudget = ComputerLimits.treeTimeBudget
    /// At most this many children of one container are read (a 10 000-row table is not walked).
    var maxChildrenPerNode = 40
}

enum SnapshotScope: Sendable {
    case frontWindow
    case window(index: Int)
    case modalFirst
}

struct CapturedWindow: @unchecked Sendable {
    var image: CGImage
    var scale: CGFloat
    var windowFrame: CGRect
    var fingerprint: UInt64
    var capturedAt: Date
    var duration: TimeInterval
}

protocol UIBackend: AnyObject {
    // permissions (truthful, never prompting)
    func accessibilityTrusted() -> Bool
    func screenCaptureAllowed() -> Bool

    // applications
    func runningApplications() async -> [ApplicationSnapshot]
    func frontmostApplication() async -> ApplicationSnapshot?
    /// Installed (not necessarily running) bundle identifier for a reference, if any.
    func installedBundleID(for ref: AppRef) async -> String?
    func launchApplication(bundleID: String) async throws -> Int32
    func activateApplication(pid: Int32) async -> Bool
    func quitApplication(pid: Int32) async -> Bool
    func isResponsive(pid: Int32) async -> Bool

    // windows
    func windows(pid: Int32) async -> [WindowSnapshot]
    func windowOperation(_ op: WindowOp, pid: Int32, windowIndex: Int) async throws

    // observation
    func snapshot(pid: Int32, scope: SnapshotScope, budget: AXBudget) async throws -> AXSnapshot
    func menuBarTitles(pid: Int32) async throws -> [String]
    func menuItems(pid: Int32, path: [String]) async throws -> [MenuItemSnapshot]
    func pressMenuPath(pid: Int32, path: [String]) async throws
    func readValue(_ h: ElementHandle) async throws -> String?

    // element operations
    func perform(_ op: ElementOp, on h: ElementHandle) async throws
    func setValue(_ text: String, on h: ElementHandle) async throws

    // synthetic input (fallbacks; always aimed at ONE process, never at the global event stream)
    func postKey(_ chord: KeyChord, toPID pid: Int32) async throws
    func typeText(_ text: String, toPID pid: Int32, shouldContinue: @escaping @Sendable () -> Bool) async throws
    func postScroll(direction: ScrollDirection, lines: Int, atGlobal p: CGPoint, toPID pid: Int32) async throws
    func postClick(atGlobal p: CGPoint, toPID pid: Int32) async throws

    // workspace
    func openFile(path: String, withBundleID bundleID: String?) async throws
    func revealInFinder(path: String) async throws
    func openSettingsPane(_ pane: SettingsPane) async throws

    // screen
    func displays() -> DisplayLayout
    func captureWindow(cgWindowID: UInt32, windowFrame: CGRect) async throws -> CapturedWindow
}
