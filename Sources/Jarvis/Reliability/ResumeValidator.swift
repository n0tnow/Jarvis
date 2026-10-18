import Foundation

// MARK: - Checkpoint hygiene and resume revalidation (V1.0 reliability pass)
//
// The task engine writes checkpoints at coherent boundaries and, after a restart, marks running tasks INTERRUPTED — nothing resumes by itself, and a resume is an explicit user action. This is the pure rule set
// for the two things around that:
//   1. WHAT MAY BE STORED: a checkpoint carries minimal, safe state — ids, step states and bounded evidence, change hashes, plan version. It never carries a secret-shaped string, a chain-of-thought marker or a
//      reference to raw audio; `CheckpointHygiene.violations` finds those so the writer can refuse.
//   2. WHAT MUST STILL BE TRUE: before a resumed task continues, current truth is compared with what the checkpoint recorded. A changed Git head, a file that no longer matches its recorded hash, a missing
//      workspace or a different plan version is a REASON TO STOP AND TELL THE PERSON, not something to paper over. Memory and the checkpoint never outrank the files.

struct ResumeSnapshot: Equatable, Sendable {
    var taskID: String
    var planVersion: Int
    var workspaceRoot: String?
    var gitHead: String?
    /// path → content hash recorded when the task last changed it.
    var fileHashes: [String: String]
    var stepStates: [String: String]
    var openApprovalIDs: [String]
}

struct ResumeTruth: Equatable, Sendable {
    var planVersion: Int
    var workspaceExists: Bool
    var gitHead: String?
    var currentFileHashes: [String: String?]
    var approvalsStillOpen: Set<String>
}

enum ResumeIssue: Equatable, Sendable {
    case workspaceMissing
    case planChanged(recorded: Int, current: Int)
    case gitHeadChanged
    case fileChanged(String)
    case fileMissing(String)
    /// Informational: an approval that was open is no longer open (decided or cancelled while JARVIS was away).
    case approvalNoLongerOpen(String)

    var blocksResume: Bool { if case .approvalNoLongerOpen = self { return false }; return true }
}

enum ResumeValidator {
    static func validate(_ s: ResumeSnapshot, against t: ResumeTruth) -> [ResumeIssue] {
        var issues: [ResumeIssue] = []
        if s.workspaceRoot != nil, !t.workspaceExists { issues.append(.workspaceMissing); return issues }
        if s.planVersion != t.planVersion { issues.append(.planChanged(recorded: s.planVersion, current: t.planVersion)) }
        if let recorded = s.gitHead, let now = t.gitHead, recorded != now { issues.append(.gitHeadChanged) }
        for (path, hash) in s.fileHashes.sorted(by: { $0.key < $1.key }) {
            switch t.currentFileHashes[path] {
            case .some(.some(let now)): if now != hash { issues.append(.fileChanged(path)) }
            case .some(.none): issues.append(.fileMissing(path))
            case .none: issues.append(.fileMissing(path))
            }
        }
        for id in s.openApprovalIDs where !t.approvalsStillOpen.contains(id) { issues.append(.approvalNoLongerOpen(id)) }
        return issues
    }

    /// A resume may proceed only when nothing BLOCKS it. Even then it re-observes: the checkpoint is a guide, never an authority.
    static func mayResume(_ issues: [ResumeIssue]) -> Bool { !issues.contains(where: \.blocksResume) }

    static func explain(_ issues: [ResumeIssue], language l: ReplyLanguage) -> String {
        let blocking = issues.filter(\.blocksResume)
        guard !blocking.isEmpty else { return l == .tr ? "Kaldığım yerden devam edebilirim; önce her şeyi yeniden gözlemlerim." : "I can continue from where I stopped; I re-observe everything first." }
        let parts = blocking.prefix(4).map { i -> String in
            switch i {
            case .workspaceMissing: return l == .tr ? "proje klasörü artık yok" : "the project folder is gone"
            case .planChanged: return l == .tr ? "plan değişmiş" : "the plan changed"
            case .gitHeadChanged: return l == .tr ? "Git'te başka bir commit var" : "Git is on a different commit"
            case .fileChanged(let p): return l == .tr ? "\((p as NSString).lastPathComponent) benden sonra değişmiş" : "\((p as NSString).lastPathComponent) changed since I last touched it"
            case .fileMissing(let p): return l == .tr ? "\((p as NSString).lastPathComponent) bulunamıyor" : "\((p as NSString).lastPathComponent) is missing"
            case .approvalNoLongerOpen: return ""
            }
        }.filter { !$0.isEmpty }
        return (l == .tr ? "Devam etmeden önce durdum: " : "I stopped before continuing: ") + parts.joined(separator: "; ") + (l == .tr ? ". Ne yapmamı istersiniz?" : ". What would you like me to do?")
    }
}

enum CheckpointHygiene {
    private static let chainOfThought = ["<thinking>", "</thinking>", "<think>", "chain of thought", "chain-of-thought", "let me think step by step", "my reasoning:", "scratchpad:", "düşünce zinciri", "adım adım düşünelim"]
    private static let audioMarkers = ["audio buffer", "pcm", "raw audio", "ham ses"]
    private static let audioExtensions = ["wav", "caf", "m4a", "aiff"]

    /// Reasons a field must NOT be written into a checkpoint (empty = safe). Content-free: names the class, never echoes the text.
    static func violations(in text: String) -> [String] {
        var out: [String] = []
        if SecretGate.containsSecret(text) { out.append("secret-shaped text") }
        let low = text.lowercased()
        if chainOfThought.contains(where: { low.contains($0) }) { out.append("chain-of-thought marker") }
        if audioMarkers.contains(where: { low.contains($0) }) || audioExtensions.contains(where: { low.contains("." + $0) }) { out.append("raw audio reference") }
        return out
    }

    /// Bounded, sanitised evidence line for a checkpoint: clipped, control characters removed; nil when it must not be stored at all.
    static func safeEvidence(_ text: String, limit: Int = 400) -> String? {
        guard violations(in: text).isEmpty else { return nil }
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? Unicode.Scalar(32) : $0 }))
        return String(cleaned.prefix(limit))
    }
}
