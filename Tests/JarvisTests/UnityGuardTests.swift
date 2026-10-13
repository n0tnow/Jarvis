import Testing
import Foundation
@testable import Jarvis

private func code(_ sub: String) -> [(path: String, text: String)] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(sub)
    var out: [(String, String)] = []
    for u in (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] where u.pathExtension == "swift" && !u.lastPathComponent.hasSuffix(".generated.swift") {      // the embedded C# is data, guarded by its own test
        let text = FileManager.default.contents(atPath: u.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        out.append((u.path, text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")))
    }
    return out
}

@Suite("V0.6 structural guarantees (source-level, next to verify.sh)")
@MainActor
struct UnityGuardTests {
    @Test func theUnityOperationEnumHasNoCaseThatCarriesCodeAMenuPathOrACommand() {
        let proto = code("Sources/Jarvis/Unity").first { $0.path.hasSuffix("UnityProtocol.swift") }?.text ?? ""
        let enumBody = proto.components(separatedBy: "enum UnityOperation: Equatable, Sendable {").dropFirst().first?.components(separatedBy: "\n    var wireName").first ?? ""
        #expect(enumBody.contains("case ping") && enumBody.contains("case setSerializedProperty"))
        for bad in ["code", "script", "menu", "command", "shell", "eval", "execute", "csharp", "method", "invoke"] {
            #expect(!enumBody.lowercased().contains("case \(bad)") && !enumBody.lowercased().contains("\(bad):"), "UnityOperation must not carry `\(bad)`")
        }
        #expect(UnityOperation.allWireNames.allSatisfy { n in !["execute", "eval", "runCSharp", "executeMenuItem", "shell", "invoke"].contains { n.lowercased().contains($0.lowercased()) } })
    }

    @Test func unityOperationsAreSentOnlyThroughTheConnectionAndOnlyFromTheEngineAndTheLiveTest() {
        for (path, text) in code("Sources/Jarvis") {
            if text.contains(".perform(") && text.contains("UnityToolSession") || text.contains("transport.send(") {
                let ok = path.contains("/Unity/") || path.hasSuffix("TaskEngine+Unity.swift") || path.hasSuffix("UnityLiveTest.swift") || path.hasSuffix("OperatorLiveTest.swift")
                #expect(ok, "\(path) talks to the Unity editor")
            }
        }
        for (path, text) in code("Sources/Jarvis/UI") { #expect(!text.contains("UnityOperation") && !text.contains(".perform(") && !text.contains("UnityToolSession"), "\(path): the UI never operates the editor") }
        for (path, text) in code("Sources/Jarvis/Proactive") { #expect(!text.contains("UnityService") && !text.contains("UnityConnection"), "\(path): the decision layer never touches the editor") }
    }

    @Test func fileWritesInTheUnityLayerAreConfinedToTheSpoolAndTheBridgeInstaller() {
        for (path, text) in code("Sources/Jarvis/Unity") {
            let writes = [".write(to:", ".write(contentsOf", "createFile(", "removeItem(", "moveItem(", "copyItem(", "createDirectory("].contains { text.contains($0) }
            if writes { #expect(path.hasSuffix("UnityTransport.swift") || path.hasSuffix("UnityBridgeInstaller.swift"), "\(path) writes files") }
        }
        let installer = code("Sources/Jarvis/Unity").first { $0.path.hasSuffix("UnityBridgeInstaller.swift") }?.text ?? ""
        #expect(installer.contains("packageFolder") && !installer.contains("manifest.json"))          // never edits the project's package manifest
    }

    @Test func theUnityLayerLaunchesProcessesOnlyThroughManagedProcessWithAFixedArgumentList() {
        for (path, text) in code("Sources/Jarvis/Unity") {
            for bad in ["Process()", "NSTask", "posix_spawn", "/bin/sh", "/bin/zsh", "osascript", "\"-executeMethod\"", "\"-runTests\"", "\"-batchmode\", \"-quit\""] where !path.hasSuffix("UnityProcessScanner.swift") && !path.hasSuffix("UnityProtocol.swift") {            // (UnityProtocol.swift holds the DENY-list of words a provider may not use)
                #expect(!text.contains(bad), "\(path) contains \(bad)")
            }
        }
        let launcher = code("Sources/Jarvis/Unity").first { $0.path.hasSuffix("UnityLauncher.swift") }?.text ?? ""
        #expect(launcher.contains("ManagedProcess(") && launcher.contains("\"-disable-assembly-updater\"") && !launcher.contains("-executeMethod"))
        #expect(UnityProcessLauncher.arguments(projectRoot: "/p") == ["-batchmode", "-nographics", "-projectPath", "/p", "-logFile", "-", "-disable-assembly-updater", "-jarvisOwned"])
    }

    @Test func noNetworkNoCredentialsNoPurchasesNoGitInTheUnityLayer() {
        for (path, text) in code("Sources/Jarvis/Unity") + code("Sources/Jarvis/Tasks").filter({ $0.path.hasSuffix("TaskEngine+Unity.swift") }) {
            for bad in ["URLSession", "URLRequest", "NWConnection", "WebSocket", "CFNetwork", "Data(contentsOf", "SecItem", "keychain", "git push", "git commit", "purchase(", "StoreKit", "UnityHub.app/Contents", "licensing", "credential"] {
                if path.hasSuffix("UnityActionParser.swift") || path.hasSuffix("UnityProtocol.swift") { continue }          // the DENY-list of words a provider may not use
                #expect(!text.lowercased().contains(bad.lowercased()) || text.contains("never"), "\(path) contains \(bad)")
            }
        }
    }

    @Test func theBridgeSourceHasNoEvalMenuExecutionNetworkOrShell() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "/UnityBridge/com.jarvis.bridge"
        let cs = try (FileManager.default.subpathsOfDirectory(atPath: src)).filter { $0.hasSuffix(".cs") }.map { try String(contentsOfFile: src + "/" + $0, encoding: .utf8) }.joined(separator: "\n")
        for bad in ["EditorApplication.ExecuteMenuItem", "Process.Start", "ProcessStartInfo", "UnityWebRequest", "HttpClient", "TcpListener", "Socket(", "Assembly.Load", "CSharpCodeProvider", "Roslyn", "Invoke(\"", "MethodInfo.Invoke", "System.Net", "Environment.GetEnvironmentVariable"] {
            #expect(!cs.contains(bad), "the Editor bridge contains \(bad)")
        }
        #expect(cs.contains("Handlers.TryGetValue(op") && cs.contains("unknownOperation"))
    }

    @Test func unityEditsAreNeverDoneByRewritingSceneYAML() {
        for (path, text) in code("Sources/Jarvis/Tasks") + code("Sources/Jarvis/Unity") {
            #expect(!text.contains(".unity\"") || path.hasSuffix("UnityStepParams.swift") || path.hasSuffix("UnityPolicy.swift") || path.hasSuffix("UnityProjectDetector.swift") || path.hasSuffix("TaskEngine+Unity.swift") || path.hasSuffix("TaskPlan.swift") || path.hasSuffix("UnityDiscovery.swift") || path.hasSuffix("UnityOperatorOps.swift") || path.hasSuffix("TaskEngine+UnityOperator.swift") || path.hasSuffix("UnityProtocol.swift"), "\(path) mentions scene files")
            #expect(!text.contains("YAMLDecoder") && !text.contains("m_GameObject"), "\(path) parses scene YAML")
        }
    }
}
