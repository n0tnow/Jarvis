import Darwin
import Foundation

// MARK: - Headless decision tools (V1.0 Phase B) — answer before any UI object exists
//
//   Jarvis --store-jev-credential          reads the TypeSafe/Jev API key from the terminal with echo OFF and stores it in the Keychain (nothing is printed, nothing is written anywhere else)
//   Jarvis --jev-check                     presence of the credential, model discovery (names), ONE minimal classification of a synthetic utterance; executes nothing
//   Jarvis --local-model-score <result.json> [--name N] [--size-gb G] [--quant Q] [--probes F]
//                                          scores a recorded run of `scripts/local-ai/bench_model.py` with the rubric (RubricCheck) and prints the report; loads no model
//   Jarvis --decision-benchmark [--corpus F] [--heldout F] [--jev] [--jev-model M] [--rows F]
//                                          deterministic baseline (no network); with --jev the classifier is asked about every case IN SHADOW (compared, never executed)
//                                          also: --adversarial F --blind F (the V1.0 reliability corpora), --suite "name=path" (any further corpus, repeatable — e.g. the Jev gating sets
//                                          Benchmarks/jev_heldout.json, jev_hard_negative.json, jev_ambiguity.json) and --project-names "A,B" (a stand-in registry for bare project names; tests only)
//   Jarvis --jev-gate-evaluate --rows F [same corpus flags]
//                                          OFFLINE (no network, no key, no Keychain): runs the rows a real `--decision-benchmark --jev --rows F` produced through the production gate
//                                          (read-only and own-UI levels, plus the execution-level SIMULATION) and prints accepted / correct / wrong / executing-false-accept counts, call counts and calibration bins
//   Jarvis --discover-projects <folder>...  lists project CANDIDATES (Unity / Xcode / SwiftPM / Git markers) under the folders you name; read-only, bounded, registers nothing
// None of this starts the app, a provider, a task or an action. The key is read only by `TypeSafeJevTransport` at request time; these tools never see it.

enum DecisionTools {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--store-jev-credential") { storeCredential() }
        if args.contains("--jev-check") { launch { await jevCheck(args) } }
        if args.contains("--decision-benchmark") { launch { await benchmark(args) } }
        if args.contains("--jev-gate-evaluate") { launch { await gateEvaluate(args) } }
        if args.contains("--local-model-score") { launch { await scoreLocalModel(args) } }
        if args.contains("--discover-projects") { discoverProjects(args) }
    }

    private static func launch(_ work: @escaping @Sendable () async -> Int32) -> Never {
        Task { exit(await work()) }
        dispatchMain()
    }

    private static func out(_ s: String) { print(s); fflush(stdout) }
    private static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    // MARK: credential

    private static func storeCredential() -> Never {
        guard isatty(STDIN_FILENO) != 0 else { err("Run this in an interactive terminal: the key is typed with echo off. Nothing was stored."); exit(2) }
        guard let secret = readHidden(prompt: "TypeSafe/Jev API key (input hidden): ") else { err("No input. Nothing was stored."); exit(2) }
        switch JevCredentialStore.store(secret) {
        case .success: out("Stored in the macOS Keychain (service \(JevCredentialStore.service)). The key was not printed or written anywhere else."); exit(0)
        case .failure(.invalid): err("That does not look like an API key (8–512 visible characters, no spaces). Nothing was stored."); exit(2)
        case .failure(.keychain(let code)): err("The Keychain refused (OSStatus \(code)). Nothing was stored."); exit(1)
        }
    }

    private static func readHidden(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        var old = termios()
        guard tcgetattr(STDIN_FILENO, &old) == 0 else { return nil }
        var raw = old
        raw.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &old); FileHandle.standardError.write(Data("\n".utf8)) }
        var line = ""
        while let c = Optional(getchar()), c != EOF, c != 10, c != 13 { line.append(Character(UnicodeScalar(UInt8(truncatingIfNeeded: c)))) }
        return line.isEmpty ? nil : line
    }

    // MARK: connectivity

    private static func jevCheck(_ args: [String]) async -> Int32 {
        out("credential present in Keychain: \(JevCredentialStore.isPresent())")
        guard JevCredentialStore.isPresent() else { out("Nothing to check: store the key first (Jarvis --store-jev-credential)."); return 1 }
        let transport = TypeSafeJevTransport()
        var alias = value(after: "--jev-model", in: args) ?? "jev-latest"
        do {
            let models = try await transport.listModels()
            out("models available to this account: \(models.isEmpty ? "(none listed)" : models.joined(separator: ", "))")
            if !models.contains(alias), let first = models.first, value(after: "--jev-model", in: args) == nil { alias = first }
        } catch let f as JevFailure { out("model discovery failed: \(f.rawValue)") } catch { out("model discovery failed") }
        let c = JevContextBuilder.build(utterance: "Sistem durumunu söyle.", language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: [])!
        let started = Date()
        do {
            let r = try await transport.complete(JevRequestBuilder.request(for: c), modelAlias: alias, timeout: 12)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let top = r.probabilities.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
            out("classification: intent=\(r.intent) confidence=\(String(format: "%.3f", r.confidence)) page=\(r.page ?? "-") model=\(r.model ?? "?") latency=\(ms) ms tokens(in/out)=\(r.inputTokens ?? -1)/\(r.outputTokens ?? -1)  [\(top)]")
            out(r.intent == "system_status" ? "RESULT: connectivity and schema OK — the expected intent came back (nothing was executed)." : "RESULT: connectivity and schema OK — but the intent differs from the expected system_status.")
            return 0
        } catch let f as JevFailure { out("classification failed: \(f.rawValue)"); return 1 } catch { out("classification failed"); return 1 }
    }

    // MARK: benchmark

    struct Row: Codable {
        var id: String, text: String, lang: String, source: String
        var expected: String, deterministic: Bool
        var det: String?, detConfidence: Double?, detExact: Bool
        var jev: String?, jevConfidence: Double?, jevSecond: String?, jevSecondProbability: Double?, jevPage: String?, jevFailure: String?, jevLatency: Double?
        var expectedExecuting: Bool
    }

    /// The corpora named on the command line: the main corpus (default path), then `--heldout`, `--adversarial`, `--blind` and any number of `--suite "name=path"`.
    private static func loadSuites(_ args: [String]) throws -> [(String, DecisionCorpus)] {
        func load(_ path: String) throws -> DecisionCorpus { try DecisionCorpus.load(from: URL(fileURLWithPath: path)) }
        var suites: [(String, DecisionCorpus)] = [("main corpus", try load(value(after: "--corpus", in: args) ?? "Benchmarks/decision_corpus.json"))]
        if let h = value(after: "--heldout", in: args) { suites.append(("held-out", try load(h))) }
        if let a = value(after: "--adversarial", in: args) { suites.append(("adversarial A", try load(a))) }
        if let b = value(after: "--blind", in: args) { suites.append(("blind B", try load(b))) }
        for (i, a) in args.enumerated() where a == "--suite" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            suites.append((parts[0], try load(parts[1])))
        }
        return suites
    }

    private static func benchmark(_ args: [String]) async -> Int32 {
        let withJev = args.contains("--jev")
        let suites: [(String, DecisionCorpus)]
        do { suites = try loadSuites(args) } catch { out("cannot read the corpus: \(error)"); return 2 }
        let provider = JevDecisionProvider(transport: TypeSafeJevTransport(), credentialAvailable: { JevCredentialStore.isPresent() })
        var cfg = JevConfig(mode: .shadow)
        cfg.timeoutSeconds = 10; cfg.maxRequestsPerHour = 100_000; cfg.breakerFailures = 1_000
        cfg.modelAlias = value(after: "--jev-model", in: args) ?? "jev-latest"
        var allRows: [String: [Row]] = [:]
        var parsers = DecisionParsers()
        if let names = value(after: "--project-names", in: args)?.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }), !names.isEmpty {
            parsers.isKnownProjectName = { spoken in names.contains { ProjectOpenResolver.nameMatches(spoken: spoken, name: $0) } }
        }
        let recognizer = DeterministicCommandRecognizer(parsers: parsers)
        for (name, corpus) in suites {
            out("\n=== \(name): \(corpus.cases.count) cases ===")
            out(DecisionBenchmarkRunner.runDeterministic(corpus, recognizer: recognizer).markdown())
            var rows: [Row] = []
            for k in corpus.cases {
                let det = recognizer.recognize(k.text, context: k.decisionContext)
                var row = Row(id: k.id, text: k.text, lang: k.lang, source: k.source, expected: k.intent.rawValue, deterministic: k.deterministic, det: det?.intent.rawValue, detConfidence: det?.confidence,
                              detExact: det.map { DecisionBenchmarkRunner.exactMatch($0, k) } ?? false, expectedExecuting: k.requiresExecution)
                if withJev, let ctx = JevContextBuilder.build(utterance: k.text, language: k.lang == "en" ? "en" : "tr", source: k.decisionContext.source, previousInterpretation: k.decisionContext.previousInterpretation, projectNames: [], config: cfg) {
                    switch await provider.decide(ctx, config: cfg) {
                    case .unavailable(let why): row.jevFailure = why.rawValue
                    case .decision(let d, let latency): row.jev = d.intent.rawValue; row.jevConfidence = d.confidence; row.jevLatency = latency; row.jevPage = d.target
                    }
                }
                rows.append(row)
            }
            allRows[name] = rows
        }
        if withJev {
            let u = provider.usage
            out("\nJev usage: requests \(u.requests) · input tokens \(u.inputTokens) · output tokens \(u.outputTokens) · failures \(u.failures) · model \(u.lastModel ?? "?")")
            out(String(format: "approximate cost from the published input price ($0.042 per million input tokens, output free): $%.6f", Double(u.inputTokens) / 1_000_000 * 0.042))
        }
        if let rowsPath = value(after: "--rows", in: args), let data = try? JSONEncoder().encode(allRows) { try? data.write(to: URL(fileURLWithPath: rowsPath)); out("rows written to \(rowsPath)") }
        return 0
    }

    // MARK: offline gate evaluation (recorded rows only)

    private static func gateEvaluate(_ args: [String]) async -> Int32 {
        guard let rowsPath = value(after: "--rows", in: args), let data = FileManager.default.contents(atPath: rowsPath),
              let rows = try? JSONDecoder().decode([String: [JevAnswerSource.RecordedRow]].self, from: data) else { out("cannot read the rows file (--rows F, written by --decision-benchmark --jev --rows F)"); return 2 }
        let suites: [(String, DecisionCorpus)]
        do { suites = try loadSuites(args) } catch { out("cannot read the corpus: \(error)"); return 2 }
        var parsers = DecisionParsers()
        if let names = value(after: "--project-names", in: args)?.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }), !names.isEmpty {
            parsers.isKnownProjectName = { spoken in names.contains { ProjectOpenResolver.nameMatches(spoken: spoken, name: $0) } }
        }
        let recognizer = DeterministicCommandRecognizer(parsers: parsers)
        out("Gate evaluation of RECORDED rows (offline). Nothing was sent anywhere; the execution level is a simulation and is never active in production.")
        for (name, corpus) in suites {
            guard let r = rows[name] else { out("\n(no recorded rows for “\(name)” — skipped)"); continue }
            for level in [JevGateLevel.readOnly, .ownUI] {
                out("\n" + JevGateEvaluator.evaluate(corpus: corpus, corpusName: name, source: .recorded(r, name: "recorded rows from \(rowsPath)"), level: level, recognizer: recognizer).markdown())
            }
        }
        return 0
    }

    // MARK: project discovery (read-only, explicit roots)

    private static func discoverProjects(_ args: [String]) -> Never {
        let roots = args.drop(while: { $0 != "--discover-projects" }).dropFirst().prefix(while: { !$0.hasPrefix("--") }).map { String($0) }
        guard !roots.isEmpty else { err("Name at least one folder: Jarvis --discover-projects ~/Projects"); exit(2) }
        let report = ProjectDiscovery.scan(roots: roots.map { ($0 as NSString).expandingTildeInPath })
        for r in report.refusedRoots { out("refused (not a project root): \(r)") }
        for r in report.missingRoots { out("not found: \(r)") }
        for c in report.candidates {
            out("\(c.kind.rawValue)\t\(c.verified ? "verified" : "unverified")\t\(c.registered ? "registered" : "NOT registered")\t\(c.path)\t\(c.suggestedAliases.isEmpty ? "" : "suggested alias: " + c.suggestedAliases.joined(separator: ", "))")
        }
        out("\(report.candidates.count) candidate(s), \(report.directoriesVisited) folder(s) looked at\(report.truncated ? " — stopped early at a budget, the list is a sample" : ""). Nothing was registered or written.")
        exit(0)
    }

    // MARK: local model scoring

    private struct RecordedRun: Decodable {
        var id: String, text: String, failed: Bool
        var ttft: Double?, generation_tps: Double?, generation_tokens: Int?, prompt_tokens: Int?, total_seconds: Double?
    }
    private struct RecordedResult: Decodable {
        var model: String, load_seconds: Double?, rss_after_load_mb: Double?, rss_after_run_mb: Double?, runs: [RecordedRun]
    }
    private final class Replay: ConversationalModelRunning, @unchecked Sendable {
        let candidate: ModelCandidate, rec: RecordedResult
        var calls = 0
        init(candidate: ModelCandidate, rec: RecordedResult) { self.candidate = candidate; self.rec = rec }
        func load() async throws -> TimeInterval? { rec.load_seconds }
        func generate(_ probe: ConversationalProbe) async -> ModelRun {
            guard let r = rec.runs.first(where: { $0.id == probe.id }) else { return ModelRun(text: "", failed: true) }
            var total = r.total_seconds
            if let n = r.generation_tokens, let tps = r.generation_tps, tps > 0 { total = Double(n) / tps }
            return ModelRun(text: r.text, timeToFirstToken: r.ttft, totalSeconds: total, outputTokens: r.generation_tokens, contextTokens: r.prompt_tokens, failed: r.failed)
        }
        func residentMemoryMB() -> Double? { calls += 1; return calls == 1 ? rec.rss_after_load_mb : rec.rss_after_run_mb }
        func unload() async {}
    }

    private static func scoreLocalModel(_ args: [String]) async -> Int32 {
        guard let path = value(after: "--local-model-score", in: args), let data = FileManager.default.contents(atPath: path), let rec = try? JSONDecoder().decode(RecordedResult.self, from: data) else { out("cannot read the recorded run"); return 2 }
        let probesPath = value(after: "--probes", in: args) ?? "Benchmarks/local_model_probes.json"
        guard let probes = try? ConversationalProbeSet.load(from: URL(fileURLWithPath: probesPath)) else { out("cannot read the probes"); return 2 }
        let name = value(after: "--name", in: args) ?? (rec.model as NSString).lastPathComponent
        let cand = ModelCandidate(id: name, displayName: name, license: nil, approximateSizeGB: value(after: "--size-gb", in: args).flatMap(Double.init), quantization: value(after: "--quant", in: args), notes: nil)
        let report = await LocalModelBenchmark.run(runner: Replay(candidate: cand, rec: rec), probes: probes, dryRun: false)
        out(report.markdown())
        out("failed probes: \(report.failures.joined(separator: ", "))")
        return 0
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
        return args[i + 1]
    }
}
