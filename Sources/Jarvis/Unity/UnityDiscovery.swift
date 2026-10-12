import Foundation

/// Finds installed Unity editors in the standard Unity Hub / legacy locations. It never scans the filesystem broadly, never opens
/// Unity, never reads account or license data and never logs in.
enum UnityDiscovery {
    static let hubEditorRoots = ["/Applications/Unity/Hub/Editor"]
    static let hubApp = "/Applications/Unity Hub.app"

    static func hubInstalled(fileManager fm: FileManager = .default) -> Bool { fm.fileExists(atPath: hubApp) }

    /// `Unity Hub` can keep editors in a user-chosen folder; its own config file records it (a plain path, no credentials).
    static func secondaryInstallRoot(home: String = NSHomeDirectory(), fileManager fm: FileManager = .default) -> String? {
        let file = home + "/Library/Application Support/UnityHub/secondaryInstallPath.json"
        guard let data = fm.contents(atPath: file), let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String,
              obj.hasPrefix("/"), !obj.contains("..") else { return nil }
        return obj
    }

    /// `roots` are directories that contain one folder per editor version (`<root>/<version>/Unity.app`).
    static func discover(roots: [String]? = nil, includeLegacyApplications: Bool = true, fileManager fm: FileManager = .default, now: Date = Date()) -> [UnityEditorInstall] {
        var dirs = roots ?? (hubEditorRoots + [secondaryInstallRoot()].compactMap { $0 })
        dirs = Array(NSOrderedSet(array: dirs)) as? [String] ?? dirs
        var found: [UnityEditorInstall] = []
        for root in dirs {
            guard let kids = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in kids.sorted() {
                guard let version = UnityVersion(name) else { continue }
                let app = "\(root)/\(name)/Unity.app"
                let exe = app + "/Contents/MacOS/Unity"
                found.append(UnityEditorInstall(version: version, appPath: app, executablePath: exe, available: fm.isExecutableFile(atPath: exe), lastCheckedAt: now))
            }
        }
        if includeLegacyApplications && roots == nil, let apps = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for a in apps.sorted() where a.hasPrefix("Unity") && a.hasSuffix(".app") && a != "Unity Hub.app" {
                let app = "/Applications/\(a)"
                let exe = app + "/Contents/MacOS/Unity"
                guard fm.isExecutableFile(atPath: exe), let v = version(ofApp: app, fileManager: fm), !found.contains(where: { $0.version == v }) else { continue }
                found.append(UnityEditorInstall(version: v, appPath: app, executablePath: exe, available: true, lastCheckedAt: now))
            }
        }
        return found.sorted { $0.version > $1.version }
    }

    private static func version(ofApp app: String, fileManager fm: FileManager) -> UnityVersion? {
        guard let data = fm.contents(atPath: app + "/Contents/Info.plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        for key in ["UnityBuildNumber", "CFBundleVersion", "CFBundleShortVersionString"] { if let s = plist[key] as? String, let v = UnityVersion(s) { return v } }
        return nil
    }

    enum Choice: Equatable {
        case exact(UnityEditorInstall)
        /// Only other versions are installed: opening the project with one of them would migrate it. Needs the user's approval.
        case needsUpgradeApproval(declared: UnityVersion, candidate: UnityEditorInstall)
        case noEditor
        case unknownDeclaredVersion
    }

    /// Never silently picks a different version: an exact match or an explicit upgrade question.
    static func choose(for declared: UnityVersion?, among installs: [UnityEditorInstall]) -> Choice {
        guard let declared else { return .unknownDeclaredVersion }
        let usable = installs.filter(\.available)
        if let exact = usable.first(where: { $0.version == declared }) { return .exact(exact) }
        // Same major release line first (the least invasive migration), else the newest.
        if let sameLine = usable.filter({ $0.version.major == declared.major }).max(by: { $0.version < $1.version }) { return .needsUpgradeApproval(declared: declared, candidate: sameLine) }
        if let newest = usable.max(by: { $0.version < $1.version }) { return .needsUpgradeApproval(declared: declared, candidate: newest) }
        return .noEditor
    }
}
