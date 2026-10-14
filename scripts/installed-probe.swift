// Developer helper for scripts/verify-installed.sh (V0.15): looks at a RUNNING JARVIS from the outside, the way a person sees it — without Screen Recording or Accessibility.
//   installed-probe windows <ownerName>      → one line per on-screen window of that app: "layer x y w h"   (window metadata only; no titles, no pixels)
//   installed-probe statusitem <bundleID>    → the menu-bar item (macOS hosts it in Control Center; its window is named after the bundle id): prints "x y w h" or nothing
//   installed-probe app <bundleID>           → "pid path activationPolicy launchDate" of each running copy
//   installed-probe terminate <bundleID>     → asks each running copy to quit normally (like ⌘Q); prints how many
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: installed-probe windows|app|terminate <name>"); exit(2) }
switch args[1] {
case "windows":
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list where (w[kCGWindowOwnerName as String] as? String) == args[2] {
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        print("\(w[kCGWindowLayer as String] as? Int ?? -1) \(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0)) onscreen=\(w[kCGWindowIsOnscreen as String] as? Bool ?? false)")
    }
case "statusitem":
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list where (w[kCGWindowLayer as String] as? Int) == 25 && (w[kCGWindowName as String] as? String) == args[2] {
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        print("\(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0))")
    }
case "app":
    for a in NSRunningApplication.runningApplications(withBundleIdentifier: args[2]) {
        print("\(a.processIdentifier) \(a.bundleURL?.path ?? "?") policy=\(a.activationPolicy.rawValue) terminated=\(a.isTerminated)")
    }
case "terminate":
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: args[2])
    apps.forEach { _ = $0.terminate() }
    print(apps.count)
default: exit(2)
}
