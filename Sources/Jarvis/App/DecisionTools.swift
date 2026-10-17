import Darwin
import Foundation

// MARK: - Headless decision tools (V1.0 Phase B) — answer before any UI object exists
//
//   Jarvis --store-jev-credential          reads the TypeSafe/Jev API key from the terminal with echo OFF and stores it in the Keychain (nothing is printed, nothing is written anywhere else)
//   Jarvis --jev-check                     presence of the credential, model discovery (names), ONE minimal classification of a synthetic utterance; executes nothing
//   Jarvis --decision-benchmark [--corpus F] [--heldout F] [--jev] [--jev-model M] [--rows F]
//                                          deterministic baseline (no network); with --jev the classifier is asked about every case IN SHADOW (compared, never executed)
// None of this starts the app, a provider, a task or an action. The key is read only by `TypeSafeJevTransport` at request time; these tools never see it.

enum DecisionTools {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--store-jev-credential") { storeCredential() }
        if args.contains("--jev-check") { launch { await jevCheck(args) } }
        if args.contains("--decision-benchmark") { launch { await benchmark(args) } }
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

    private static func benchmark(_ args: [String]) async -> Int32 {
        let corpusPath = value(after: "--corpus", in: args) ?? "Benchmarks/decision_corpus.json"
        let heldPath = value(after: "--heldout", in: args)
        let withJev = args.contains("--jev")
        var suites: [(String, DecisionCorpus)] = []
        do {
            suites.append(("main corpus", try DecisionCorpus.load(from: URL(fileURLWithPath: corpusPath))))
            if let h = heldPath { suites.append(("held-out", try DecisionCorpus.load(from: URL(fileURLWithPath: h)))) }
        } catch { out("cannot read the corpus: \(error)"); return 2 }
        let provider = JevDecisionProvider(transport: TypeSafeJevTransport(), credentialAvailable: { JevCredentialStore.isPresent() })
        var cfg = JevConfig(mode: .shadow)
        cfg.timeoutSeconds = 10; cfg.maxRequestsPerHour = 100_000; cfg.breakerFailures = 1_000
        cfg.modelAlias = value(after: "--jev-model", in: args) ?? "jev-latest"
        var allRows: [String: [Row]] = [:]
        let recognizer = DeterministicCommandRecognizer()
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

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
        return args[i + 1]
    }
}
