import Testing
import Foundation
@testable import Jarvis

// V0.15 structural guarantees (source level, next to scripts/guards_v15.sh): the daily layer is presentation, references and readiness — never authority, never persistence, never a process.

private func code(_ sub: String) -> [(path: String, text: String)] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(sub)
    var out: [(String, String)] = []
    for u in (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] where u.pathExtension == "swift" {
        let text = FileManager.default.contents(atPath: u.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        out.append((u.path, text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")))
    }
    return out
}

@Suite("V0.15 structural guarantees (source-level, next to guards_v15.sh)")
struct DailyStructuralTests {
    @Test func theDailyAndReadinessLayersCannotApproveDecideOrGrant() {
        for (path, text) in code("Sources/Jarvis/Daily") + code("Sources/Jarvis/Readiness") {
            for bad in [".approve(", ".deny(", "approveByStandingPolicy", "AdaptiveDecisionSource", "pendingApproval", "requestApproval", "CapabilitySet", "TaskCapability"] {
                #expect(!text.contains(bad), "\(path) contains \(bad)")
            }
        }
    }

    @Test func theyPlanNothingAndRunNoAgentAndSubmitNoTask() {
        for (path, text) in code("Sources/Jarvis/Daily") + code("Sources/Jarvis/Readiness") {
            for bad in ["OrchestratedPlan", "GraphValidator", "OrchestrationPlanner", "AgentJob(", "StepAgentRunner", "engine.submit(", "taskEngine.submit(", ".submitTask(", "submitResearch("] {
                #expect(!text.contains(bad), "\(path) contains \(bad)")
            }
            #expect(text.range(of: "(class|struct|enum|actor) +[A-Za-z]*Orchestrat", options: .regularExpression) == nil, "\(path) declares an orchestrator")
        }
    }

    @Test func theyNeverPollOrScheduleAnything() {
        for (path, text) in code("Sources/Jarvis/Daily") + code("Sources/Jarvis/Readiness") {
            for bad in ["Timer.", "scheduledTimer", "asyncAfter", "Task.sleep", "makeTimerSource"] { #expect(!text.contains(bad), "\(path) contains \(bad)") }
        }
    }

    @Test func theyNeverTouchCredentialsKeychainOrCookies() {
        for (path, text) in code("Sources/Jarvis/Daily") + code("Sources/Jarvis/Readiness") {
            for bad in ["SecItem", "kSec", "Keychain", "HTTPCookie", "binarycookies", "credential.", "auth.json", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] { #expect(!text.contains(bad), "\(path) contains \(bad)") }
        }
    }

    @Test func setupHasNoShellSudoDownloaderOrUrl() {
        for (path, text) in code("Sources/Jarvis/Readiness") {
            for bad in ["sudo", "curl", "wget", "osascript", "brew ", "pip install", "npm install", "/bin/sh", "/bin/zsh", "http://", "https://", "Process()"] { #expect(!text.contains(bad), "\(path) contains \(bad)") }
        }
        let launches = code("Sources/Jarvis/Readiness").reduce(0) { $0 + $1.text.components(separatedBy: "ManagedProcess(").count - 1 }
        #expect(launches == 1, "exactly one process launch in Readiness/ (the packaged script), found \(launches)")
    }

    @Test func noSetupActionCarriesTextAUrlOrACommandOrNamesAnExternalCli() {
        for a in SetupAction.allCases {
            let n = a.rawValue.lowercased()
            for bad in ["url", "command", "shell", "script", "path", "text", "claude", "codex", "opencode", "mcp", "brew", "npm", "pip", "download", "paid", "api", "subscription", "purchase"] { #expect(!n.contains(bad), "\(a) mentions \(bad)") }
        }
        #expect(SetupAction.allCases.count == 16)
    }

    @Test func theWorkingContextIsEphemeralAndBounded() {
        let ctxFile = code("Sources/Jarvis/Daily").first { $0.path.hasSuffix("WorkingContext.swift") }?.text ?? ""
        for bad in ["UserDefaults", "JSONEncoder", "JSONDecoder", "NSKeyedArchiver", "createFile(", ".write(to:", "JarvisRepository", "ProjectMemory", "MemoryService", "LearningService", "Codable"] { #expect(!ctxFile.contains(bad), "WorkingContext contains \(bad)") }
        #expect(ConversationWorkingContext.capacity == 16 && ConversationWorkingContext.maxAge == 1800 && ConversationWorkingContext.maxTurns == 30)
    }

    @Test func nothingOutsideTheAllowedFilesTouchesTheWorkingContext() {
        let allowed = ["Daily/", "Services/Conversation/ConversationService.swift", "App/AppContext+Daily.swift", "App/DailyLiveTest.swift", "UI/Settings/DailySettingsSection.swift"]
        for (path, text) in code("Sources/Jarvis") where text.contains("workingContext") { #expect(allowed.contains { path.contains($0) }, "\(path) touches the working context") }
    }

    @Test func entitlementsListExactlyTheMicrophone() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Jarvis.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any]
        #expect(plist?.keys.sorted() == ["com.apple.security.device.audio-input"])
    }

    @Test func theInfoPlistHasOnlyTheMicrophonePrivacyKeyAndIsAMenuBarAgent() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any] ?? [:]
        #expect(plist.keys.filter { $0.hasSuffix("UsageDescription") }.sorted() == ["NSMicrophoneUsageDescription"])
        #expect(plist["LSUIElement"] as? Bool == true && plist["CFBundleIdentifier"] as? String == "dev.jarvis.Jarvis")
    }

    @Test func nothingInTheAppReadsAPathFromTheRepositoryOrTheWorkingDirectory() {
        let allowed = ["LiveTest", "StabilitySoak", "VisualBenchmark", "SmokeTest", "DevCapture", "Services/Demo/", "Research/URLPolicy", "Research/MCPDiscovery", "Tasks/CommandProfiles"]
        for (path, text) in code("Sources/Jarvis") {
            for bad in ["#filePath", "currentDirectoryPath", "xcodebuild", "swift run"] where text.contains(bad) { #expect(allowed.contains { path.contains($0) }, "\(path) contains \(bad)") }
        }
    }
}
