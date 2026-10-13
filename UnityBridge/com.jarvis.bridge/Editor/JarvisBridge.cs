using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using UnityEditor;
using UnityEditor.Compilation;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Jarvis.Bridge
{
    /// <summary>
    /// JARVIS Editor bridge. A FIXED list of typed operations, driven by request files in Library/JarvisBridge/requests and answered in
    /// responses/. There is no network socket, no eval, no arbitrary menu item and no way to run C# supplied by a caller: an operation
    /// that is not registered below is rejected. State changes are published to status.json so the host never has to poll.
    /// </summary>
    [InitializeOnLoad]
    public static class JarvisBridge
    {
        public const int ProtocolVersion = 1;
        public const string BridgeVersion = "0.13.0";

        public delegate Dictionary<string, object> Handler(Dictionary<string, object> args);

        public static readonly string ProjectPath;
        public static readonly string Root;
        public static readonly string RequestsDir, ResponsesDir, TestsDir;
        /// <summary>Filled in by the optional test-runner assembly.</summary>
        public static Func<string> TestRunSignatureHook = () => "";
        public static Func<Dictionary<string, object>> TestRunSummaryHook = () => null;
        static readonly Dictionary<string, Handler> Handlers = new Dictionary<string, Handler>();
        static readonly HashSet<string> Mutating = new HashSet<string>();
        static readonly ConcurrentQueue<Dictionary<string, object>> LogQueue = new ConcurrentQueue<Dictionary<string, object>>();
        static double nextTick;
        static string lastSignature = "";
        static long consoleSeq;
        static string sessionId;
        static int reloadCount;
        static bool owned;
        static int tickCount;

        // Compilation bookkeeping (persisted to compile.json so a domain reload or a new editor session still has the last result).
        static int compileGeneration;
        static bool compileRunning;
        static string compileStartedAt;
        static readonly List<Dictionary<string, object>> compileErrors = new List<Dictionary<string, object>>();
        static int compileWarnings;

        static JarvisBridge()
        {
            ProjectPath = Directory.GetParent(Application.dataPath).FullName;
            Root = Path.Combine(ProjectPath, "Library", "JarvisBridge");
            RequestsDir = Path.Combine(Root, "requests");
            ResponsesDir = Path.Combine(Root, "responses");
            TestsDir = Path.Combine(Root, "tests");
            try
            {
                Directory.CreateDirectory(RequestsDir);
                Directory.CreateDirectory(ResponsesDir);
                Directory.CreateDirectory(TestsDir);
            }
            catch (Exception) { return; }

            sessionId = SessionState.GetString("Jarvis.Bridge.session", "");
            if (string.IsNullOrEmpty(sessionId))
            {
                sessionId = Guid.NewGuid().ToString("N");
                SessionState.SetString("Jarvis.Bridge.session", sessionId);
                SessionState.SetInt("Jarvis.Bridge.reloads", 0);
            }
            else SessionState.SetInt("Jarvis.Bridge.reloads", SessionState.GetInt("Jarvis.Bridge.reloads", 0) + 1);
            reloadCount = SessionState.GetInt("Jarvis.Bridge.reloads", 0);
            owned = Environment.GetCommandLineArgs().Contains("-jarvisOwned");
            consoleSeq = ConsoleLog.LastSequence();
            LoadCompileState();

            Ops.RegisterAll();
            Application.logMessageReceivedThreaded += OnLog;
            CompilationPipeline.compilationStarted += OnCompilationStarted;
            CompilationPipeline.assemblyCompilationFinished += OnAssemblyCompiled;
            CompilationPipeline.compilationFinished += OnCompilationFinished;
            EditorApplication.playModeStateChanged += _ => nextTick = 0;
            EditorApplication.update += Tick;
            nextTick = 0;
            lastSignature = "";   // forces the first status write
        }

        // ---------------------------------------------------------------- registration (used by Ops and optional assemblies)

        public static void Register(string op, Handler handler, bool mutating = false)
        {
            Handlers[op] = handler;
            if (mutating) Mutating.Add(op); else Mutating.Remove(op);
        }

        public static bool IsOwned => owned;
        public static string SessionId => sessionId;
        public static int ReloadCount => reloadCount;
        public static int CompileGeneration => compileGeneration;
        public static bool CompileRunning => compileRunning;
        public static List<Dictionary<string, object>> CompileErrors => compileErrors;
        public static int CompileWarnings => compileWarnings;
        public static string CompileStartedAt => compileStartedAt;

        // ---------------------------------------------------------------- tick (inside the editor only; the host does not poll)

        static void Tick()
        {
            double now = EditorApplication.timeSinceStartup;
            if (now < nextTick) return;
            nextTick = now + 0.1;
            tickCount++;
            try
            {
                DrainLog();
                ProcessOneRequest();
                PublishStatusIfChanged();
            }
            catch (Exception e)
            {
                System.Diagnostics.Debug.WriteLine("[JarvisBridge] " + e.Message);
            }
        }

        static void ProcessOneRequest()
        {
            string[] files;
            try { files = Directory.GetFiles(RequestsDir, "*.json"); } catch (Exception) { return; }
            if (files.Length == 0) return;
            Array.Sort(files, StringComparer.Ordinal);
            var path = files[0];
            Dictionary<string, object> req = null;
            string id = Path.GetFileNameWithoutExtension(path);
            string text = null;
            try { text = File.ReadAllText(path); req = Json.Parse(text) as Dictionary<string, object>; }
            catch (Exception) { /* partially written or invalid: treat as invalid */ }

            // Already answered (replay after a domain reload): just remove the request.
            if (File.Exists(Path.Combine(ResponsesDir, id + ".json"))) { TryDelete(path); return; }

            Dictionary<string, object> response;
            var started = DateTime.UtcNow;
            if (req == null) response = Fail(id, "invalidRequest", "The request file is not valid JSON.");
            else
            {
                if (req.TryGetValue("id", out var rid) && rid is string rs && rs.Length > 0) id = rs;
                response = Dispatch(id, req);
            }
            response["id"] = id;
            response["session"] = sessionId;
            response["reloads"] = reloadCount;
            response["ms"] = (DateTime.UtcNow - started).TotalMilliseconds;
            AtomicWrite(Path.Combine(ResponsesDir, id + ".json"), Json.Serialize(response));
            TryDelete(path);
        }

        static Dictionary<string, object> Dispatch(string id, Dictionary<string, object> req)
        {
            string op = req.TryGetValue("op", out var o) ? o as string : null;
            if (string.IsNullOrEmpty(op) || !Handlers.TryGetValue(op, out var handler))
                return Fail(id, "unknownOperation", "Operation \"" + (op ?? "") + "\" is not part of the JARVIS bridge protocol.");
            var args = req.TryGetValue("params", out var p) ? p as Dictionary<string, object> : null;
            if (args == null) args = new Dictionary<string, object>();
            if (Mutating.Contains(op))
            {
                if (EditorApplication.isPlaying || EditorApplication.isPlayingOrWillChangePlaymode)
                    return Fail(id, "playModeMutationBlocked", "Persistent project changes are not allowed while Play Mode is active.");
                if (EditorApplication.isCompiling || EditorApplication.isUpdating)
                    return Fail(id, "editorBusy", "The editor is compiling or importing; try again when it is idle.");
            }
            try
            {
                var result = handler(args);
                return new Dictionary<string, object> { { "ok", true }, { "result", result ?? new Dictionary<string, object>() } };
            }
            catch (OpException e)
            {
                var r = Fail(id, e.Code, e.Message);
                if (e.Extra != null) ((Dictionary<string, object>)r["error"])["details"] = e.Extra;
                return r;
            }
            catch (Exception e)
            {
                return Fail(id, "internal", Trim(e.GetType().Name + ": " + e.Message, 400));
            }
        }

        internal static Dictionary<string, object> Fail(string id, string code, string message) =>
            new Dictionary<string, object> { { "ok", false }, { "error", new Dictionary<string, object> { { "code", code }, { "message", message } } } };

        // ---------------------------------------------------------------- status.json (written ONLY when something changes)

        static void PublishStatusIfChanged()
        {
            var scenes = LoadedScenes();
            var sig = new StringBuilder();
            sig.Append(EditorApplication.isCompiling).Append('|').Append(EditorApplication.isPlaying).Append('|').Append(EditorApplication.isPlayingOrWillChangePlaymode)
               .Append('|').Append(EditorApplication.isPaused).Append('|').Append(EditorApplication.isUpdating).Append('|').Append(compileGeneration).Append('|').Append(compileRunning);
            foreach (var s in scenes) sig.Append('|').Append(s.path).Append(':').Append(s.isDirty);
            sig.Append('|').Append(Ops.TestRunSignature());
            var signature = sig.ToString();
            if (signature == lastSignature) return;
            lastSignature = signature;
            WriteStatus(scenes);
        }

        internal static void ForceStatus() { lastSignature = ""; nextTick = 0; }

        static List<Scene> LoadedScenes()
        {
            var l = new List<Scene>();
            for (int i = 0; i < SceneManager.sceneCount; i++) l.Add(SceneManager.GetSceneAt(i));
            return l;
        }

        static void WriteStatus(List<Scene> scenes)
        {
            string state = EditorApplication.isCompiling ? "compiling"
                : EditorApplication.isPlaying ? (EditorApplication.isPaused ? "paused" : "playing")
                : EditorApplication.isPlayingOrWillChangePlaymode ? "enteringPlay"
                : EditorApplication.isUpdating ? "importing" : "edit";
            var active = SceneManager.GetActiveScene();
            var sceneList = new List<object>();
            foreach (var s in scenes)
                sceneList.Add(new Dictionary<string, object> { { "path", s.path }, { "name", s.name }, { "dirty", s.isDirty }, { "jarvisDirty", Ops.IsJarvisDirty(s.path) }, { "loaded", s.isLoaded } });
            var status = new Dictionary<string, object>
            {
                { "protocol", ProtocolVersion },
                { "bridgeVersion", BridgeVersion },
                { "pid", System.Diagnostics.Process.GetCurrentProcess().Id },
                { "session", sessionId },
                { "owned", owned },
                { "project", ProjectPath },
                { "projectName", Path.GetFileName(ProjectPath) },
                { "unityVersion", Application.unityVersion },
                { "batchMode", Application.isBatchMode },
                { "graphics", SystemInfo.graphicsDeviceType.ToString() },
                { "state", state },
                { "isCompiling", EditorApplication.isCompiling },
                { "isPlaying", EditorApplication.isPlaying },
                { "reloads", reloadCount },
                { "compileGeneration", compileGeneration },
                { "compileFailed", EditorUtility.scriptCompilationFailed },
                { "compileRunning", compileRunning },
                { "activeScene", active.path },
                { "scenes", sceneList },
                { "testRun", Ops.TestRunSummary() },
                { "updatedAt", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() },
            };
            AtomicWrite(Path.Combine(Root, "status.json"), Json.Serialize(status));
        }

        // ---------------------------------------------------------------- console capture (bounded ring file; sanitized by the host)

        static void OnLog(string message, string stack, LogType type)
        {
            LogQueue.Enqueue(new Dictionary<string, object>
            {
                { "t", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() },
                { "type", type.ToString() },
                { "message", Trim(message, 1800) },
                { "stack", Trim(stack, 1200) },
            });
        }

        static void DrainLog()
        {
            if (LogQueue.IsEmpty) return;
            var lines = new List<string>();
            int n = 0;
            while (n < 200 && LogQueue.TryDequeue(out var e))
            {
                e["seq"] = ++consoleSeq;
                lines.Add(Json.Serialize(e));
                n++;
            }
            ConsoleLog.Append(lines);
        }

        // ---------------------------------------------------------------- compilation tracking

        static void OnCompilationStarted(object _)
        {
            compileGeneration++;
            compileRunning = true;
            compileStartedAt = DateTime.UtcNow.ToString("o");
            compileErrors.Clear();
            compileWarnings = 0;
            SaveCompileState();
            lastSignature = "";
        }

        static void OnAssemblyCompiled(string assembly, CompilerMessage[] messages)
        {
            foreach (var m in messages)
            {
                if (m.type == CompilerMessageType.Error && compileErrors.Count < 50)
                    compileErrors.Add(new Dictionary<string, object> { { "file", m.file ?? "" }, { "line", m.line }, { "column", m.column }, { "message", Trim(m.message, 400) }, { "assembly", Path.GetFileName(assembly) } });
                else if (m.type == CompilerMessageType.Warning) compileWarnings++;
            }
        }

        static void OnCompilationFinished(object _)
        {
            compileRunning = false;
            SaveCompileState();
            lastSignature = "";
        }

        static void SaveCompileState()
        {
            var d = new Dictionary<string, object>
            {
                { "generation", compileGeneration }, { "running", compileRunning }, { "startedAt", compileStartedAt ?? "" },
                { "succeeded", compileErrors.Count == 0 }, { "errors", compileErrors }, { "warnings", compileWarnings },
                { "finishedAt", compileRunning ? "" : DateTime.UtcNow.ToString("o") },
            };
            AtomicWrite(Path.Combine(Root, "compile.json"), Json.Serialize(d));
        }

        static void LoadCompileState()
        {
            try
            {
                var f = Path.Combine(Root, "compile.json");
                if (!File.Exists(f)) return;
                var d = Json.Parse(File.ReadAllText(f)) as Dictionary<string, object>;
                if (d == null) return;
                compileGeneration = d.TryGetValue("generation", out var g) && g is double gd ? (int)gd : 0;
                compileWarnings = d.TryGetValue("warnings", out var w) && w is double wd ? (int)wd : 0;
                compileStartedAt = d.TryGetValue("startedAt", out var sa) ? sa as string : null;
                compileRunning = false;                     // a reload means the previous compile ended
                compileErrors.Clear();
                if (d.TryGetValue("errors", out var er) && er is List<object> el)
                    foreach (var x in el) if (x is Dictionary<string, object> xd) compileErrors.Add(xd);
            }
            catch (Exception) { /* start fresh */ }
        }

        // ---------------------------------------------------------------- helpers

        public static void AtomicWrite(string path, string content)
        {
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, content, new UTF8Encoding(false));
            // Replace in one step: a reader must never see the file missing between a delete and a move.
            if (File.Exists(path)) File.Replace(tmp, path, null);
            else File.Move(tmp, path);
        }

        static void TryDelete(string path) { try { File.Delete(path); } catch (Exception) { } }

        public static string Trim(string s, int max) => string.IsNullOrEmpty(s) ? "" : (s.Length <= max ? s : s.Substring(0, max));
    }

    /// <summary>A rejected operation with a stable machine-readable code.</summary>
    public sealed class OpException : Exception
    {
        public readonly string Code;
        public readonly object Extra;
        public OpException(string code, string message, object extra = null) : base(message) { Code = code; Extra = extra; }
    }

    /// <summary>Console capture file: one JSON object per line, bounded (older lines are dropped).</summary>
    internal static class ConsoleLog
    {
        static string FilePath => Path.Combine(JarvisBridge.Root, "console.jsonl");
        const int MaxBytes = 1_500_000;

        public static void Append(List<string> lines)
        {
            try
            {
                File.AppendAllText(FilePath, string.Join("\n", lines) + "\n", new UTF8Encoding(false));
                var info = new FileInfo(FilePath);
                if (info.Length > MaxBytes)
                {
                    var all = File.ReadAllLines(FilePath);
                    File.WriteAllLines(FilePath, all.Skip(all.Length / 2).ToArray());
                }
            }
            catch (Exception) { }
        }

        public static long LastSequence()
        {
            try
            {
                if (!File.Exists(FilePath)) return 0;
                string last = null;
                foreach (var l in File.ReadLines(FilePath)) if (l.Length > 2) last = l;
                if (last == null) return 0;
                var d = Json.Parse(last) as Dictionary<string, object>;
                return d != null && d.TryGetValue("seq", out var s) && s is double sd ? (long)sd : 0;
            }
            catch (Exception) { return 0; }
        }

        public static List<object> Read(long afterSeq, int max, HashSet<string> types, out long lastSeq)
        {
            var list = new List<object>();
            lastSeq = LastSequence();
            try
            {
                if (!File.Exists(FilePath)) return list;
                foreach (var l in File.ReadLines(FilePath))
                {
                    if (l.Length < 3) continue;
                    var d = Json.Parse(l) as Dictionary<string, object>;
                    if (d == null || !(d["seq"] is double sd) || (long)sd <= afterSeq) continue;
                    if (types != null && types.Count > 0 && !types.Contains((string)d["type"])) continue;
                    list.Add(d);
                    if (list.Count >= max) break;
                }
            }
            catch (Exception) { }
            return list;
        }
    }
}
