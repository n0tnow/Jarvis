import Foundation

enum EvidenceCheck: Equatable, Sendable {
    case stillPresent
    case resolved(String)
    case unknown
}

/// Before an approved proposal runs, check (read-only, deterministically) that the issue it was about still exists. If every
/// machine-checkable claim is now false the opportunity is OBSOLETE and nothing is modified.
enum EvidenceRevalidator {
    static func check(_ evidence: [EvidenceItem], projectRoot: String) -> EvidenceCheck {
        let predicates = evidence.compactMap(\.predicate)
        guard !predicates.isEmpty else { return .unknown }
        guard let ws = try? WorkspaceGuard(rootPath: projectRoot) else { return .unknown }
        let tools = ProjectTools(workspace: ws, capabilities: .readOnly)
        var resolved: [String] = []
        for p in predicates {
            switch p {
            case .fileContains(let path, let text):
                let content = (try? tools.readFile(path, maxBytes: 200_000).text) ?? nil
                if content?.contains(text) != true { resolved.append("\(path) no longer contains the reported text") }
            case .fileLacks(let path, let text):
                if let content = (try? tools.readFile(path, maxBytes: 200_000).text), content.contains(text) { resolved.append("\(path) now contains the missing text") }
            case .fileExists(let path):
                if (try? tools.exists(path)) != true { resolved.append("\(path) no longer exists") }
            case .fileMissing(let path):
                if (try? tools.exists(path)) == true { resolved.append("\(path) now exists") }
            }
        }
        return resolved.count == predicates.count ? .resolved(resolved.joined(separator: "; ")) : .stillPresent
    }
}
