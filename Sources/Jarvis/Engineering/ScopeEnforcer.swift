import Foundation

// MARK: - Write-scope enforcement (V1.0 autonomous engineering pipeline)
//
// An assignment says which files may change. After a worker, the OBSERVED change set is compared with it: a change outside `allowed`, a forbidden or protected path,
// an unauthorised test / build-script / guard / dependency-manifest change, a deletion that was not allowed, a file that was the user's own uncommitted work,
// and a diff whose size does not fit the task's expected magnitude. Nothing here decides what to DO about it (reject, ask for an explanation, ask for broader authority) —
// it reports typed findings; the engine's existing approval and lease machinery stays the authority.

enum ScopeEnforcer {
    static func check(changes: [FileChange], scope: WriteScope, attribution: AttributionReport? = nil, userDirtyBefore: Set<String> = []) -> [EngineeringFinding] {
        var out: [EngineeringFinding] = []
        let dirty = Set(userDirtyBefore.map(PathGlob.normalize))
        for c in changes {
            let classes = PathClassifier.classes(of: c.path)
            if scope.isReadOnly { out.append(EngineeringFinding(.readOnlyAssignmentChanged, .blocker, path: c.path, "a read-only assignment changed a file", evidence: "\(c.kind.rawValue) \(c.path)")); continue }
            if scope.isForbidden(c.path) { out.append(EngineeringFinding(.forbiddenPath, .blocker, path: c.path, "the path is explicitly forbidden for this assignment", evidence: "\(c.kind.rawValue) \(c.path)")); continue }
            if scope.protectedPatterns.contains(where: { PathGlob.matches($0, c.path) }) { out.append(EngineeringFinding(.protectedPath, .blocker, path: c.path, "the path is protected in this project", evidence: "\(c.kind.rawValue) \(c.path)")); continue }
            if classes.contains(.secretMaterial) { out.append(EngineeringFinding(.protectedPath, .blocker, path: c.path, "credential / signing material is never a worker's to change", evidence: "\(c.kind.rawValue) \(c.path)")); continue }
            if !scope.allows(c.path) { out.append(EngineeringFinding(.scopeEscape, .blocker, path: c.path, "the change is outside the files this assignment allows", evidence: "\(c.kind.rawValue) \(c.path)")) }
            if c.kind == .deleted, !scope.mayDelete { out.append(EngineeringFinding(.deletionNotAllowed, .blocker, path: c.path, "this assignment does not allow deleting files", evidence: "deleted \(c.path)")) }
            if classes.contains(.test), !scope.mayModifyTests {
                out.append(EngineeringFinding(.testModifiedWithoutAuthority, c.kind == .deleted ? .blocker : .major, path: c.path, "a test file changed although the assignment does not authorise test changes", evidence: "\(c.kind.rawValue) \(c.path)"))
            }
            if classes.contains(.buildScript), !scope.mayModifyBuildScripts { out.append(EngineeringFinding(.buildScriptChanged, .blocker, path: c.path, "a build / test-runner / CI script changed without authority", evidence: "\(c.kind.rawValue) \(c.path)")) }
            if classes.contains(.securityGuard), !scope.mayModifyGuards { out.append(EngineeringFinding(.guardChanged, .blocker, path: c.path, "a security guard, approval, credential or policy file changed without authority", evidence: "\(c.kind.rawValue) \(c.path)")) }
            if classes.contains(.dependencyManifest), !scope.mayAddDependencies { out.append(EngineeringFinding(.dependencyAdded, .major, path: c.path, "a dependency manifest changed; dependencies need a stated reason, version and source", evidence: "\(c.kind.rawValue) \(c.path)")) }
            if c.isBinary, !classes.contains(.binaryAsset) || !scope.allows(c.path) { out.append(EngineeringFinding(.binaryFileChanged, .major, path: c.path, "a binary file changed", evidence: "\(c.kind.rawValue) \(c.path)")) }
            if classes.contains(.generated) { out.append(EngineeringFinding(.generatedFileChanged, .minor, path: c.path, "a generated / build-output file changed", evidence: "\(c.kind.rawValue) \(c.path)")) }
            if dirty.contains(PathGlob.normalize(c.path)) { out.append(EngineeringFinding(.userDirtyFileTouched, .major, path: c.path, "the file carried the user's own uncommitted work before the task", evidence: "\(c.kind.rawValue) \(c.path)")) }
        }
        if let a = attribution {
            for u in a.unexplained { out.append(EngineeringFinding(.unexplainedChange, .major, path: u.change.path, "the file changed during the task but no applied edit explains it", evidence: "\(u.change.kind.rawValue) \(u.change.path)")) }
        }
        out += magnitude(changes: changes, scope: scope)
        return out
    }

    /// A 2-file task that changes 73 files deserves scrutiny; a 40-file refactor that was EXPECTED to change 30–50 does not. No universal line threshold: only the task's own expectation counts.
    static func magnitude(changes: [FileChange], scope: WriteScope) -> [EngineeringFinding] {
        guard let expected = scope.expectedFileCount else { return [] }
        let n = changes.count
        let upper = max(expected.upperBound, 1)
        if n > upper * 10 && n > upper + 10 { return [EngineeringFinding(.largeDiff, .blocker, path: ".", "the change touches \(n) files; the task expected at most \(upper)", evidence: "\(n) files changed, expected \(expected.lowerBound)…\(upper)")] }
        if n > max(upper * 2, upper + 3) { return [EngineeringFinding(.largeDiff, .major, path: ".", "the change touches \(n) files; the task expected at most \(upper)", evidence: "\(n) files changed, expected \(expected.lowerBound)…\(upper)")] }
        return []
    }
}
