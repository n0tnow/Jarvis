import Foundation

// MARK: - Content-level checks on what a worker actually changed (V1.0 autonomous engineering pipeline)
//
// These run on the OBSERVED before/after text of changed files (`FileDelta`), never on the worker's description. They look for the ways a worker "makes a failure disappear" or leaves
// the work hollow: deleted / skipped / weakened tests, weakened guards, suppressed build failures, placeholders, silent error suppression, introduced secrets, unsafe commands.
// They are structural (declaration kinds, assertion counts, operator relaxation, empty handlers), language-aware only where it matters (comments are stripped per language) and
// deliberately do NOT flag a test that was changed for a reason — a changed test is reported so someone reviews why, a REMOVED or DISABLED one blocks.
// A secret is never echoed: the evidence names the path and line number only.

struct FileDelta: Equatable, Sendable {
    var path: String
    var before: String?
    var after: String?
    var isDeleted: Bool { after == nil }
    var isCreated: Bool { before == nil }
}

struct LineDelta: Equatable, Sendable {
    var added: [String]
    var removed: [String]
}

enum LineDiffer {
    /// Order-insensitive multiset difference of trimmed non-empty lines: moved code is neither added nor removed.
    static func diff(_ before: String?, _ after: String?) -> LineDelta {
        func counts(_ t: String?) -> [String: Int] {
            var c: [String: Int] = [:]
            for l in (t ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
                let s = l.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { c[s, default: 0] += 1 }
            }
            return c
        }
        let (b, a) = (counts(before), counts(after))
        var added: [String] = [], removed: [String] = []
        // keep file order for the added lines (stable evidence)
        var surplusAdded = a.mapValues { $0 }
        for (k, v) in b { surplusAdded[k] = (surplusAdded[k] ?? 0) - v }
        for l in (after ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            let s = l.trimmingCharacters(in: .whitespaces)
            if let n = surplusAdded[s], n > 0 { added.append(s); surplusAdded[s] = n - 1 }
        }
        var surplusRemoved = b.mapValues { $0 }
        for (k, v) in a { surplusRemoved[k] = (surplusRemoved[k] ?? 0) - v }
        for l in (before ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            let s = l.trimmingCharacters(in: .whitespaces)
            if let n = surplusRemoved[s], n > 0 { removed.append(s); surplusRemoved[s] = n - 1 }
        }
        return LineDelta(added: added, removed: removed)
    }
}

private func rx(_ p: String, _ o: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
private extension NSRegularExpression {
    func hits(_ s: String) -> Bool { firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    func count(in s: String) -> Int { numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) }
}

enum TamperingDetector {
    // MARK: patterns (character classes keep command words from appearing as literals in the product sources)
    private static let testDecl = rx(#"^\s*(?:@Test\b|func\s+test\w*\s*\(|def\s+test_\w*|(?:it|test|describe)\s*\(|\[Test\]|\[Fact\]|public\s+void\s+Test\w*|func\s+Test\w*\s*\()"#)
    private static let assertion = rx(#"(?:\bassert\w*\s*[(.]|XCTAssert\w*|#expect\(|#require\(|\bexpect\s*\(|\bAssert\.\w+|\.should\b|\brequire\(|\bt\.(?:Error|Fatal)\w*\(|\bself\.assert\w+)"#)
    private static let skipMarker = rx(#"(?:@Test\([^)]*\.disabled|XCTSkip|\.skip\s*\(|\bxit\s*\(|\bxdescribe\s*\(|@pytest\.mark\.skip|@unittest\.skip|\[Ignore\]|t\.Skip\(|#if\s+false|\.todo\s*\(|pytest\.skip\()"#)
    private static let unconditionalAssert = rx(#"(?:assert\s*\(\s*true\s*\)|XCTAssertTrue\(\s*true\s*\)|#expect\(\s*true\s*\)|assertTrue\(\s*True\s*\)|self\.assertTrue\(\s*True\s*\)|expect\(\s*true\s*\)\.toBe\(\s*true\s*\)|assert\s+True\b)"#)
    private static let equalityish = rx(#"(?:==|AssertEqual|assertEqual|toBe\(|toEqual\(|\.equals\()"#)
    private static let lenientish = rx(#"(?:NotNil|NotNone|!=\s*nil|>=|<=|\bTrue\(|toBeTruthy|is not None|isNotNull|NotEmpty|toBeDefined|assertIn\(|assertIsInstance|assertGreater|assertLess)"#)
    private static let guardWord = rx(#"(?:forbid|guard|deny|block|refus|never|reject|approval|critical|secret|credential|sanitiz|paid|capabilit|v09_none|hasre|permission|ungrantable|neverGranted)"#)
    private static let approvalBypass = rx(#"(?:autoApprove|skipApproval|bypassApproval|requiresApproval\s*=\s*false|needsApproval\s*=\s*false|allowPaid\w*|enablePaid\w*|disableGuard\w*|isFree\s*=\s*true|approved\s*=\s*true\s*//?\s*(?:always|force)|\.neverGranted\s*=\s*\[\s*\])"#)
    private static let buildSuppress = rx(#"(?:\|\|\s*true\b|\bexit\s+0\b|continue-on-error:\s*true|\bset\s+\+e\b|\|\|\s*:\s*$)"#)
    private static let buildCore = rx(#"(?:\bexit\s+1\b|\bset\s+-e|swift\s+test|\bpytest\b|npm\s+(?:run\s+)?test|unittest|go\s+test|cargo\s+test|xcodebuild|dotnet\s+test|guards|scripts/test)"#)
    private static let placeholderCode = rx(#"(?:fatalError\(\s*"[^"]*(?:not implemented|unimplemented|todo)|\bnotImplemented\b|NotImplementedError|NotImplementedException|\bunimplemented!\s*\(|\btodo!\s*\(|throw\s+new\s+Error\(\s*['"]not implemented|\bplaceholder implementation\b|\btemporary bypass\b|\bstub\b\s*(?:implementation|function|method)|return\s+nil\s*//\s*stub)"#)
    private static let placeholderComment = rx(#"(?:\bTODO\b|\bFIXME\b|\bXXX\b|\bHACK\b)"#, [])
    private static let emptyCatchMulti = rx(#"catch\s*(?:\([^)]*\))?\s*\{\s*\}"#)
    private static let exceptPassMulti = rx(#"except\s*[\w\s,.()]*:\s*(?:\n\s*)?pass\b"#)
    private static let swallowedPromise = rx(#"\.catch\(\s*\(\s*\w*\s*\)\s*=>\s*\{\s*\}\s*\)"#)
    private static let tryQuestionStatement = rx(#"^\s*try\?\s"#)
    private static let shellRedirect = rx(#"(?:2>\s*/dev/null|>\s*/dev/null\s+2>&1|\|\|\s*true\b|\bset\s+\+e\b)"#)
    private static let destructiveGit = rx(#"git\s+(?:res[e]t\s+--hard|cle[a]n\s+-\w*f|pus[h]\s+(?:-f\b|--force)|check[o]ut\s+-f\b|filter-bran[c]h|re[b]ase\s+-i)"#)
    private static let destructiveShell = rx(#"(?:\brm\s+-\w*r\w*f?\w*\s+(?:/|~|\$HOME|\*)|\bcur[l]\b[^|\n]*\|\s*(?:ba|z)?sh\b|\bwge[t]\b[^|\n]*\|\s*(?:ba|z)?sh\b|chmod\s+-R\s+777|\bmkfs\b|:\(\)\s*\{\s*:\|:&)"#)
    private static let injectionRisk = rx(#"(?:\beval\s*[(\"'$]|\bos\.system\(|subprocess\.\w+\([^)]*shell\s*=\s*True|/bin/(?:ba|z)?sh["']?\s*,\s*["']-c|\bexec\(\s*(?:request|input|user)|Runtime\.getRuntime\(\)\.exec)"#)

    private static func codeOnly(_ line: String, path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let slash: Set<String> = ["swift", "js", "ts", "tsx", "jsx", "cs", "java", "kt", "go", "rs", "c", "h", "m", "mm", "cpp"]
        let hash: Set<String> = ["py", "sh", "bash", "zsh", "yml", "yaml", "toml", "rb", "mk"]
        var s = line
        if slash.contains(ext), let r = s.range(of: "//") { s = String(s[..<r.lowerBound]) }
        if hash.contains(ext) || (ext.isEmpty && ["makefile", "dockerfile"].contains((path as NSString).lastPathComponent.lowercased())) {
            if s.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return "" }
            if let r = s.range(of: " #") { s = String(s[..<r.lowerBound]) }
        }
        return s
    }

    private static func isCommentOnly(_ line: String, path: String) -> Bool { codeOnly(line, path: path).trimmingCharacters(in: .whitespaces).isEmpty }

    /// Everything the content-level detectors find for one changed file. `requirementWords`: words from the task's requirements (a placeholder that mentions one is more serious).
    static func inspect(_ d: FileDelta, scope: WriteScope = WriteScope(), requirementWords: Set<String> = []) -> [EngineeringFinding] {
        var out: [EngineeringFinding] = []
        let classes = PathClassifier.classes(of: d.path)
        let delta = LineDiffer.diff(d.before, d.after)
        let isTest = classes.contains(.test)
        let isBuild = classes.contains(.buildScript)
        let isGuard = classes.contains(.securityGuard)
        let isDoc = classes.contains(.documentation)
        let ext = (d.path as NSString).pathExtension.lowercased()
        let textual = !classes.contains(.binaryAsset)

        // ---- tests
        if isTest {
            if d.isDeleted { out.append(EngineeringFinding(.testDeleted, .blocker, path: d.path, "a test file was deleted", evidence: "deleted \(d.path)")) }
            else {
                let removedDecl = delta.removed.filter { testDecl.hits($0) }, addedDecl = delta.added.filter { testDecl.hits($0) }
                if removedDecl.count > addedDecl.count { out.append(EngineeringFinding(.testDeleted, .blocker, path: d.path, "\(removedDecl.count - addedDecl.count) test case(s) were removed", evidence: removedDecl.first ?? "")) }
                if let skip = delta.added.first(where: { skipMarker.hits($0) }) { out.append(EngineeringFinding(.testSkipped, .blocker, path: d.path, "a test was skipped or disabled", evidence: skip)) }
                if let u = delta.added.first(where: { unconditionalAssert.hits($0) }) { out.append(EngineeringFinding(.assertionWeakened, .blocker, path: d.path, "an assertion that cannot fail was added", evidence: u)) }
                let removedAsserts = delta.removed.filter { assertion.hits($0) }, addedAsserts = delta.added.filter { assertion.hits($0) }
                if removedAsserts.count > addedAsserts.count, removedDecl.count <= addedDecl.count {
                    out.append(EngineeringFinding(.assertionWeakened, .blocker, path: d.path, "\(removedAsserts.count - addedAsserts.count) assertion(s) were removed", evidence: removedAsserts.first ?? ""))
                } else if !removedAsserts.isEmpty, !addedAsserts.isEmpty {
                    if removedAsserts.contains(where: { equalityish.hits($0) }), addedAsserts.contains(where: { lenientish.hits($0) && !equalityish.hits($0) }) {
                        out.append(EngineeringFinding(.assertionWeakened, .blocker, path: d.path, "an equality assertion was replaced by a weaker one", evidence: addedAsserts.first ?? ""))
                    } else {
                        out.append(EngineeringFinding(.assertionChanged, .major, path: d.path, "an assertion's expectation changed: review whether the old expectation or the new one is right", evidence: addedAsserts.first ?? ""))
                    }
                }
                if !(delta.added.isEmpty && delta.removed.isEmpty), !scope.mayModifyTests { out.append(EngineeringFinding(.testModifiedWithoutAuthority, .major, path: d.path, "a test changed without authority", evidence: "modified \(d.path)")) }
            }
        }

        guard textual, let after = d.after else { return finish(out) }

        // ---- security guards, approval and credential logic (any source file may weaken one)
        if isGuard {
            let removed = delta.removed.filter { guardWord.hits($0) }.count, added = delta.added.filter { guardWord.hits($0) }.count
            if removed > added { out.append(EngineeringFinding(.guardWeakened, .blocker, path: d.path, "guard / approval / credential logic lost \(removed - added) line(s)", evidence: delta.removed.first(where: { guardWord.hits($0) }) ?? "")) }
            else if !delta.added.isEmpty || !delta.removed.isEmpty { out.append(EngineeringFinding(.guardChanged, .major, path: d.path, "a security guard, approval or credential file changed: elevated review", evidence: "modified \(d.path)")) }
        }
        if !isTest, !isDoc, let bypass = delta.added.first(where: { approvalBypass.hits(codeOnly($0, path: d.path)) }) {
            out.append(EngineeringFinding(.guardWeakened, .blocker, path: d.path, "an approval / paid-provider / guard bypass was introduced", evidence: bypass))
        }

        // ---- build scripts, test runners, CI
        if isBuild {
            if let s = delta.added.first(where: { buildSuppress.hits(codeOnly($0, path: d.path)) }) { out.append(EngineeringFinding(.buildFailureSuppressed, .blocker, path: d.path, "a build / test failure can no longer fail the script", evidence: s)) }
            let removedCore = delta.removed.filter { buildCore.hits($0) }, addedCore = delta.added.filter { buildCore.hits(codeOnly($0, path: d.path)) }
            if removedCore.count > addedCore.count { out.append(EngineeringFinding(.buildFailureSuppressed, .blocker, path: d.path, "a build / test / guard step was removed or commented out", evidence: removedCore.first ?? "")) }
            else if !delta.added.isEmpty || !delta.removed.isEmpty { out.append(EngineeringFinding(.buildScriptChanged, .major, path: d.path, "a build script changed: review that no failure was hidden", evidence: "modified \(d.path)")) }
        }

        // ---- placeholders (compared with the requirements, not banned outright)
        if !isDoc {
            for line in delta.added {
                let code = codeOnly(line, path: d.path)
                if placeholderCode.hits(code) {
                    out.append(EngineeringFinding(.placeholderCode, isTest ? .minor : .major, path: d.path, "a placeholder / not-implemented construct was added", evidence: line)); break
                }
            }
            if let c = delta.added.first(where: { placeholderComment.hits($0) && isCommentOrTrailing($0, path: d.path) }) {
                let words = Set(c.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                let related = !words.isDisjoint(with: requirementWords)
                out.append(EngineeringFinding(.placeholderComment, related ? .major : .minor, path: d.path, related ? "a TODO that mentions a stated requirement was left behind" : "a TODO / FIXME comment was added", evidence: c))
            }
        }

        // ---- silent error suppression
        if !isDoc {
            let beforeText = d.before ?? ""
            if emptyCatchMulti.count(in: after) > emptyCatchMulti.count(in: beforeText) { out.append(EngineeringFinding(.silentErrorSuppression, .major, path: d.path, "an empty catch block was added", evidence: "an empty catch in \(d.path)")) }
            if exceptPassMulti.count(in: after) > exceptPassMulti.count(in: beforeText) { out.append(EngineeringFinding(.silentErrorSuppression, .major, path: d.path, "an except-pass handler was added", evidence: "except … pass in \(d.path)")) }
            if swallowedPromise.count(in: after) > swallowedPromise.count(in: beforeText) { out.append(EngineeringFinding(.silentErrorSuppression, .major, path: d.path, "a rejected promise is swallowed", evidence: "an empty .catch in \(d.path)")) }
            if ext == "swift", let t = delta.added.first(where: { tryQuestionStatement.hits($0) }) { out.append(EngineeringFinding(.silentErrorSuppression, .minor, path: d.path, "a failing call's error is discarded (try? as a statement)", evidence: t)) }
            if ["sh", "bash", "zsh", "yml", "yaml"].contains(ext) || ext.isEmpty, !isBuild, let r = delta.added.first(where: { shellRedirect.hits(codeOnly($0, path: d.path)) }) {
                out.append(EngineeringFinding(.silentErrorSuppression, .minor, path: d.path, "an exit status or stderr is ignored", evidence: r))
            }
        }

        // ---- secrets (never echoed)
        for (i, line) in delta.added.enumerated() where SecretGate.containsSecret(line) {
            out.append(EngineeringFinding(.secretIntroduced, .blocker, path: d.path, "a credential-shaped value was introduced", evidence: "added line \(i + 1) of \(d.path)")); break
        }

        // ---- unsafe commands and injection risks (docs may quote commands)
        for line in delta.added {
            let code = isDoc ? line : codeOnly(line, path: d.path)
            if destructiveGit.hits(code) || destructiveShell.hits(code) {
                out.append(EngineeringFinding(.unsafeCommand, isDoc ? .minor : .blocker, path: d.path, "a destructive git / shell command was introduced", evidence: line)); break
            }
        }
        if !isDoc, let line = delta.added.first(where: { injectionRisk.hits(codeOnly($0, path: d.path)) }) {
            out.append(EngineeringFinding(.shellInjectionRisk, .major, path: d.path, "a shell / eval construct that can execute injected text was introduced", evidence: line))
        }
        return finish(out)
    }

    private static func isCommentOrTrailing(_ line: String, path: String) -> Bool {
        // a TODO only counts when it is in a comment (not inside an identifier or a string that merely contains the word)
        let code = codeOnly(line, path: path)
        return code.count < line.count || isCommentOnly(line, path: path)
    }

    private static func finish(_ f: [EngineeringFinding]) -> [EngineeringFinding] { f }

    static func inspectAll(_ deltas: [FileDelta], scope: WriteScope = WriteScope(), requirementWords: Set<String> = []) -> [EngineeringFinding] {
        deltas.flatMap { inspect($0, scope: scope, requirementWords: requirementWords) }
    }
}
