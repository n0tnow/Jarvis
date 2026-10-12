#if JARVIS_HAS_TEST_FRAMEWORK
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.TestTools.TestRunner.Api;
using UnityEngine;

namespace Jarvis.Bridge
{
    using D = Dictionary<string, object>;

    /// <summary>
    /// Unity Test Framework operations (only compiled when com.unity.test-framework is installed). Runs a FILTERED set of tests in the open
    /// editor and records the structured outcome; it never executes anything but the project's own [Test] methods.
    /// </summary>
    [InitializeOnLoad]
    static class JarvisTestOps
    {
        static TestRunnerApi api;
        static bool registered;
        static string StateFile => Path.Combine(JarvisBridge.TestsDir, "current.json");

        static JarvisTestOps()
        {
            JarvisBridge.Register("getTestAvailability", Availability, false);
            JarvisBridge.Register("runTests", RunTests, false);
            JarvisBridge.Register("getTestRun", GetRun, false);
            JarvisBridge.Register("cancelTests", Cancel, false);
            JarvisBridge.TestRunSignatureHook = () => File.Exists(StateFile) ? File.GetLastWriteTimeUtc(StateFile).Ticks.ToString() : "";
            JarvisBridge.TestRunSummaryHook = () => Summary();
            EnsureCallbacks();
        }

        static void EnsureCallbacks()
        {
            if (registered) return;
            api = ScriptableObject.CreateInstance<TestRunnerApi>();
            api.RegisterCallbacks(new Callbacks());
            registered = true;
        }

        static D Summary()
        {
            var d = Read();
            if (d == null) return null;
            var s = new D();
            foreach (var k in new[] { "runId", "mode", "state", "total", "passed", "failed", "skipped", "inconclusive" }) if (d.TryGetValue(k, out var v)) s[k] = v;
            return s;
        }

        static D Read()
        {
            try { return File.Exists(StateFile) ? Json.Parse(File.ReadAllText(StateFile)) as D : null; } catch (Exception) { return null; }
        }
        static void Write(D d) { JarvisBridge.AtomicWrite(StateFile, Json.Serialize(d)); }

        static D Availability(D a) => new D { { "available", true }, { "frameworkVersion", "installed" } };

        static TestMode ModeOf(D a)
        {
            var m = a.TryGetValue("mode", out var v) ? v as string : null;
            if (m == "editMode") return TestMode.EditMode;
            if (m == "playMode") return TestMode.PlayMode;
            throw new OpException("invalidArguments", "mode must be editMode or playMode.");
        }

        static D RunTests(D a)
        {
            var current = Read();
            if (current != null && current.TryGetValue("state", out var st) && (string)st == "running")
            {
                // A run that cannot still be alive (another editor session, or a synchronous EditMode run that outlived a domain reload) is abandoned.
                bool sameSession = current.TryGetValue("session", out var ss) && (string)ss == JarvisBridge.SessionId;
                bool edit = current.TryGetValue("mode", out var mm) && (string)mm == "editMode";
                bool reloaded = current.TryGetValue("reloads", out var rl) && rl is double rd && (int)rd != JarvisBridge.ReloadCount;
                if (sameSession && !(edit && reloaded)) throw new OpException("testRunActive", "A test run is already in progress.");
                current["state"] = "abandoned"; current["finishedAt"] = DateTime.UtcNow.ToString("o");
                Write(current);
            }
            if (EditorApplication.isCompiling) throw new OpException("editorBusy", "Scripts are compiling.");
            if (EditorUtility.scriptCompilationFailed) throw new OpException("compileErrors", "The project has script compile errors; tests cannot run.");
            // The test runner saves/restores scenes and asks the user about unsaved ones. JARVIS never answers that dialog on the user's behalf.
            for (int i = 0; i < UnityEngine.SceneManagement.SceneManager.sceneCount; i++)
            {
                var sc = UnityEngine.SceneManagement.SceneManager.GetSceneAt(i);
                if (sc.isDirty) throw new OpException("dirtyScene", "Scene \"" + (string.IsNullOrEmpty(sc.path) ? sc.name : sc.path) + "\" has unsaved changes; tests cannot run until it is saved or the changes are discarded.");
            }
            var mode = ModeOf(a);
            var filter = new Filter { testMode = mode };
            var names = (a.TryGetValue("testNames", out var tn) ? tn as List<object> : null)?.OfType<string>().Take(50).ToArray();
            var groups = (a.TryGetValue("groupNames", out var gn) ? gn as List<object> : null)?.OfType<string>().Take(20).ToArray();
            var assemblies = (a.TryGetValue("assemblyNames", out var an) ? an as List<object> : null)?.OfType<string>().Take(20).ToArray();
            if (names != null && names.Length > 0) filter.testNames = names;
            if (groups != null && groups.Length > 0) filter.groupNames = groups;
            if (assemblies != null && assemblies.Length > 0) filter.assemblyNames = assemblies;
            string runId = Guid.NewGuid().ToString("N");
            Write(new D { { "runId", runId }, { "mode", mode == TestMode.EditMode ? "editMode" : "playMode" }, { "state", "running" }, { "startedAt", DateTime.UtcNow.ToString("o") }, { "session", JarvisBridge.SessionId }, { "reloads", JarvisBridge.ReloadCount },
                          { "total", 0 }, { "passed", 0 }, { "failed", 0 }, { "skipped", 0 }, { "inconclusive", 0 }, { "cases", new List<object>() },
                          { "requested", new D { { "testNames", names ?? new string[0] }, { "groupNames", groups ?? new string[0] }, { "assemblyNames", assemblies ?? new string[0] } } } });
            var settings = new ExecutionSettings(filter) { runSynchronously = mode == TestMode.EditMode };
            try { api.Execute(settings); }
            catch (Exception e)
            {
                var failed = Read() ?? new D();
                failed["state"] = "error"; failed["error"] = JarvisBridge.Trim(e.Message, 300); failed["finishedAt"] = DateTime.UtcNow.ToString("o");
                Write(failed);
                throw new OpException("testRunFailed", "The test run could not start: " + JarvisBridge.Trim(e.Message, 200));
            }
            return new D { { "accepted", true }, { "runId", runId }, { "mode", mode == TestMode.EditMode ? "editMode" : "playMode" } };
        }

        static D GetRun(D a)
        {
            var d = Read();
            if (d == null) throw new OpException("noTestRun", "No test run has been started.");
            return d;
        }

        static D Cancel(D a)
        {
            var d = Read();
            if (d == null || !d.ContainsKey("state") || (string)d["state"] != "running") return new D { { "cancelled", false } };
            try { var m = typeof(TestRunnerApi).GetMethod("CancelTestRun", new[] { typeof(string) }); if (m != null) m.Invoke(null, new object[] { (string)d["runId"] }); } catch (Exception) { }
            d["state"] = "cancelled"; d["finishedAt"] = DateTime.UtcNow.ToString("o");
            Write(d);
            return new D { { "cancelled", true } };
        }

        sealed class Callbacks : ICallbacks
        {
            public void RunStarted(ITestAdaptor testsToRun) { }
            public void TestStarted(ITestAdaptor test) { }
            public void TestFinished(ITestResultAdaptor result) { }

            public void RunFinished(ITestResultAdaptor result)
            {
                var d = Read() ?? new D();
                var cases = new List<object>();
                int passed = 0, failed = 0, skipped = 0, inconclusive = 0;
                Walk(result, cases, ref passed, ref failed, ref skipped, ref inconclusive);
                d["state"] = "finished";
                d["finishedAt"] = DateTime.UtcNow.ToString("o");
                d["total"] = passed + failed + skipped + inconclusive;
                d["passed"] = passed; d["failed"] = failed; d["skipped"] = skipped; d["inconclusive"] = inconclusive;
                d["durationSeconds"] = result.Duration;
                d["cases"] = cases;
                Write(d);
            }

            static void Walk(ITestResultAdaptor r, List<object> cases, ref int passed, ref int failed, ref int skipped, ref int inconclusive)
            {
                if (r.HasChildren)
                {
                    foreach (var c in r.Children) Walk(c, cases, ref passed, ref failed, ref skipped, ref inconclusive);
                    return;
                }
                string status = r.TestStatus.ToString();
                switch (r.TestStatus)
                {
                    case TestStatus.Passed: passed++; break;
                    case TestStatus.Failed: failed++; break;
                    case TestStatus.Skipped: skipped++; break;
                    default: inconclusive++; break;
                }
                if (cases.Count < 200)
                    cases.Add(new D { { "name", r.FullName }, { "status", status }, { "duration", r.Duration }, { "message", JarvisBridge.Trim(r.Message, 600) }, { "stack", JarvisBridge.Trim(r.StackTrace, 500) } });
            }
        }
    }
}
#endif
