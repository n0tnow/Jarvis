import AppKit
import CryptoKit
import Foundation

/// `Jarvis --setup-live-test` — OPT-IN (V0.15). The typed setup flow on a DISPOSABLE fixture: a fake packaged-scripts folder in a temporary directory, never the real scripts, never a real download,
/// never your installed runtimes or models. REAL = the real SetupRunner and the real processes it starts; POLICY = a deterministic refusal. No network, no provider, no quota.
@MainActor
enum SetupLiveTest {
    static func run(context: AppContext) async {
        var passes = 0, failures = 0
        func check(_ tag: String, _ name: String, _ ok: Bool, _ detail: String = "") { print("\(ok ? "PASS" : "FAIL")  [\(tag)] \(name)\(detail.isEmpty ? "" : " — \(detail)")"); if ok { passes += 1 } else { failures += 1 }; fflush(stdout) }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { ProcessRegistry.shared.killAll(); print("SETUP LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("jarvis-setup-live-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let state = work.appendingPathComponent("state", isDirectory: true)
        try? fm.createDirectory(at: state, withIntermediateDirectories: true)

        func bundle(_ python: String, mode: Int = 0o755, name: String? = nil) -> URL {
            let root = work.appendingPathComponent("bundle-\(UUID().uuidString.prefix(6))", isDirectory: true)
            let dir = root.appendingPathComponent("scripts", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in name.map({ [$0] }) ?? ["setup_local_ai.sh", "setup_voice_ai.sh", "setup_vision_ai.sh", "setup_memory_ai.sh"] {       // every action finds its (fake) script
                let url = dir.appendingPathComponent(n)
                try? ("#!/usr/bin/python3\n" + python).write(to: url, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            }
            return root
        }
        func runner(_ root: URL?, free: Int64 = 100_000_000_000, uv: Bool = true) -> SetupRunner {
            let r = SetupRunner()
            r.resourceRoot = { root }; r.freeBytes = { free }; r.findTool = { _ in uv }
            r.environment = { ["PATH": "/usr/bin:/bin", "HOME": work.path] }
            return r
        }
        let finalFile = state.appendingPathComponent("model.bin"), part = state.appendingPathComponent("model.bin.part")
        let pinned = SHA256.hash(data: Data("the pinned payload".utf8)).map { String(format: "%02x", $0) }.joined()

        // 1. missing dependency
        check("POLICY", "uv missing: nothing starts and the reason is plain", await runner(bundle("print('x')"), uv: false).start(.installLocalModelRuntime) == .uvMissing)
        // 2. an existing, valid installation is reused
        let existing = bundle("import os, sys\nf = '\(finalFile.path)'\nif os.path.exists(f):\n    print('already present: nothing to download'); sys.exit(0)\nprint('would download'); sys.exit(1)\n")
        try? Data("the pinned payload".utf8).write(to: finalFile)
        let r2 = runner(existing); _ = await r2.start(.installLocalModelRuntime)
        check("REAL", "An existing valid installation is reused: the script reports it and downloads nothing", r2.log.contains { $0.contains("already present") } && { if case .finished(_, ok: true, _) = r2.state { return true }; return false }())
        try? fm.removeItem(at: finalFile)
        // 3. corrupted / interrupted partial download, then a safe restart that resumes
        let resumable = bundle("""
        import os, sys, hashlib
        part, final = '\(part.path)', '\(finalFile.path)'
        if os.path.exists(final): print('already present'); sys.exit(0)
        if os.path.exists(part):
            print('resuming from the partial file')
            os.replace(part, final); print('promoted atomically'); sys.exit(0)
        open(part, 'w').write('half of the pay'); print('downloading… interrupted'); sys.exit(1)
        """)
        let r3 = runner(resumable)
        _ = await r3.start(.installLocalModelRuntime)
        check("REAL", "An interrupted download leaves only a .part file and the run reports failure — nothing half-installed is used", { if case .finished(_, ok: false, _) = r3.state { return true }; return false }() && fm.fileExists(atPath: part.path) && !fm.fileExists(atPath: finalFile.path))
        let r3b = runner(resumable); _ = await r3b.start(.installLocalModelRuntime)
        check("REAL", "Running it again resumes and promotes atomically from staging", { if case .finished(_, ok: true, _) = r3b.state { return true }; return false }() && fm.fileExists(atPath: finalFile.path) && !fm.fileExists(atPath: part.path))
        try? fm.removeItem(at: finalFile)
        // 4. checksum mismatch: never promoted
        let mismatch = bundle("""
        import os, sys, hashlib
        part, final = '\(part.path)', '\(finalFile.path)'
        open(part, 'w').write('a different payload')
        digest = hashlib.sha256(open(part, 'rb').read()).hexdigest()
        if digest != '\(pinned)':
            os.remove(part); print('checksum mismatch for model.bin'); sys.exit(1)
        os.replace(part, final)
        """)
        let r4 = runner(mismatch); _ = await r4.start(.installSpeechRecognizer)
        check("REAL", "A checksum mismatch fails the run, removes the partial file and promotes nothing", { if case .finished(_, ok: false, let s) = r4.state { return s.contains("checksum mismatch") }; return false }() && !fm.fileExists(atPath: finalFile.path) && !fm.fileExists(atPath: part.path))
        // 5. insufficient disk (simulated)
        let r5 = runner(bundle("print('x')"), free: 5_000_000)
        let refusal = await r5.start(.installVisionHelper)
        check("POLICY", "Insufficient disk space is refused before anything starts, with the numbers", { if case .notEnoughSpace(let n, let a)? = refusal { return n > a }; return false }() && r5.log.isEmpty)
        // 6. cancellation, then restart
        let slow = bundle("import time, sys\nprint('started', flush=True)\ntime.sleep(30)\n")
        let r6 = runner(slow)
        let t6 = Task { await r6.start(.installNaturalVoice) }
        for _ in 0..<150 where !r6.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        // 7. a duplicate request while it runs
        let dup = await r6.start(.installMemoryHelper)
        check("POLICY", "A second setup request while one runs is refused", dup == .alreadyRunning)
        for _ in 0..<100 where r6.log.isEmpty { try? await Task.sleep(for: .milliseconds(40)) }
        await r6.cancel(); _ = await t6.value
        check("REAL", "Cancel stops the whole script and the state says cancelled", r6.state == .cancelled(.installNaturalVoice))
        // 8. unexpected executable / escaping link / outside folder
        let noexec = bundle("print('x')", mode: 0o644)
        let noexecRefusal = await runner(noexec).start(.installLocalModelRuntime)
        check("POLICY", "A script that is not executable is not run", { if case .scriptNotSafe? = noexecRefusal { return true }; return false }())
        let outside = work.appendingPathComponent("outside.sh"); try? "#!/usr/bin/python3\nprint('pwned')\n".write(to: outside, atomically: true, encoding: .utf8); try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        let linked = bundle("print('x')"); let linkPath = linked.appendingPathComponent("scripts/setup_local_ai.sh"); try? fm.removeItem(at: linkPath); try? fm.createSymbolicLink(at: linkPath, withDestinationURL: outside)
        let rl = runner(linked); let linkRefusal = await rl.start(.installLocalModelRuntime)
        check("POLICY", "A script that is a link to somewhere else is never run", linkRefusal != nil && rl.log.isEmpty)
        // 9. unknown source / arbitrary URL / free-text commands are not expressible
        check("POLICY", "There is no setup action for an arbitrary source: unknown names do not exist, and no action carries a URL or a command", SetupAction(rawValue: "installFromURL") == nil && SetupAction(rawValue: "runCommand") == nil
              && SetupAction.allCases.allSatisfy { SetupCatalog.plan(for: $0).map { p in p.arguments.allSatisfy { !$0.contains("://") && !$0.contains(";") && !$0.contains("|") && !$0.contains("$") } && !p.script.contains("/") } ?? true })
        // 10. paid / unknown price
        let paid = ReadinessService.build({ var p = ReadinessProbes(); p.versionLine = { "x" }; return p }())
        check("POLICY", "A paid API is not an installable dependency; a signed-in subscription never enables one", paid.item("provider.paid")?.action == nil && SetupCatalog.plan(for: .recheck) == nil
              && SetupAction.allCases.filter(\.isInstall).allSatisfy { !(SetupCatalog.plan(for: $0)?.source.lowercased().contains("api key") ?? false) })
        // 11. model folders: symlink escape and archives with traversal
        let model = work.appendingPathComponent("model-folder", isDirectory: true); try? fm.createDirectory(at: model, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: model.appendingPathComponent("config.json")); try? Data("w".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        let ok = ModelFolderValidator.validate(model, home: work.path)
        try? fm.createSymbolicLink(at: model.appendingPathComponent("leak.safetensors"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let esc = ModelFolderValidator.validate(model, home: work.path)
        check("POLICY", "A model folder is referenced where it is; a link that leaves the folder makes it refused", { if case .ok = ok { return true }; return false }() && { if case .refused(let w) = esc { return w.contains("leak.safetensors") }; return false }())
        let zip = work.appendingPathComponent("evil.zip")
        try? ZipBuilder.build([ZipBuilder.file("../../escape.txt", "x"), ZipBuilder.file("ok.txt", "y")]).write(to: zip)
        let inspected = try? ArchiveInspector.inspect(fileURL: zip, kind: "zip")
        check("POLICY", "An archive with a path-traversal entry is rejected by the inspection that runs before anything is extracted", inspected?.inspection.rejectedReason != nil, inspected?.inspection.rejectedReason ?? "not rejected")
        let ln = work.appendingPathComponent("link.zip"); try? ResearchFixtureSite.symlinkZip().write(to: ln)
        check("POLICY", "An archive containing a symbolic link is rejected too", (try? ArchiveInspector.inspect(fileURL: ln, kind: "zip"))?.inspection.rejectedReason != nil)
        // 12. the real packaged scripts: present, pinned, no shell input, no credentials
        if let res = Bundle.main.resourceURL, fm.fileExists(atPath: res.appendingPathComponent("setup/scripts").path) {
            let names = ["setup_local_ai.sh", "setup_voice_ai.sh", "setup_vision_ai.sh", "setup_memory_ai.sh"]
            let texts = names.map { n in fm.contents(atPath: res.appendingPathComponent("setup/scripts/\(n)").path).map { String(decoding: $0, as: UTF8.self) } ?? "" }
            check("REAL", "The packaged setup scripts pin their sources (revisions / hashes) and ask for no API key", texts.allSatisfy { !$0.isEmpty && !$0.contains("API_KEY") } && texts.joined().contains("REVISION=") && texts.joined().contains("sha256"))
        } else { info("this copy has no packaged setup scripts (a development bundle): the packaging script checks them for the installable app") }

        try? fm.removeItem(at: work)
        ProcessRegistry.shared.killAll()
        print("SETUP LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed, 0 skipped)"); fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
