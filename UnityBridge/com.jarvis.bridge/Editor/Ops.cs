using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using UnityEditor;
using UnityEditor.Compilation;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Jarvis.Bridge
{
    using D = Dictionary<string, object>;

    /// <summary>
    /// The complete, fixed operation table. Every operation is typed, bounded and returns structured data. Anything that would let a caller
    /// supply code (eval, menu item by name, shell) does not exist here by design.
    /// </summary>
    internal static class Ops
    {
        const int MaxObjects = 200;
        const int MaxProps = 60;
        const int MaxDepth = 4;

        // Scenes JARVIS itself dirtied are remembered in SessionState: a dirty scene that is NOT among them is the user's unsaved work.
        public static bool IsJarvisDirty(string scenePath)
        {
            if (string.IsNullOrEmpty(scenePath)) return false;
            var raw = SessionState.GetString("Jarvis.Bridge.dirty", "");
            return raw.Split('|').Contains(scenePath ?? "");
        }
        static void SetJarvisDirty(string scenePath, bool on)
        {
            var set = new HashSet<string>(SessionState.GetString("Jarvis.Bridge.dirty", "").Split('|').Where(x => x.Length > 0));
            if (on) set.Add(scenePath ?? ""); else set.Remove(scenePath ?? "");
            SessionState.SetString("Jarvis.Bridge.dirty", string.Join("|", set));
        }

        public static string TestRunSignature() => JarvisBridge.TestRunSignatureHook();
        public static D TestRunSummary() => JarvisBridge.TestRunSummaryHook();

        public static void RegisterAll()
        {
            var R = (Action<string, JarvisBridge.Handler, bool>)((n, h, m) => JarvisBridge.Register(n, h, m));
            R("ping", Ping, false);
            R("getProjectInfo", GetProjectInfo, false);
            R("listScenes", ListScenes, false);
            R("getActiveScene", GetActiveScene, false);
            R("openScene", OpenScene, false);
            R("listRootGameObjects", ListRoots, false);
            R("findGameObjects", FindGameObjects, false);
            R("inspectGameObject", InspectGameObject, false);
            R("inspectComponents", InspectComponents, false);
            R("inspectSerializedProperties", InspectSerialized, false);
            R("inspectPrefab", InspectPrefab, false);
            R("readConsole", ReadConsole, false);
            R("getCompilationState", GetCompilation, false);
            R("getPlayModeState", GetPlayMode, false);
            R("getTestAvailability", args => new D { { "available", false }, { "reason", "The Unity Test Framework package is not installed in this project." } }, false);

            R("requestCompilation", RequestCompilation, false);       // not a persistent change itself; allowed to start while the editor is idle
            R("enterPlayMode", EnterPlay, false);
            R("exitPlayMode", ExitPlay, false);
            R("shutdown", Shutdown, false);

            R("createGameObject", CreateGameObject, true);
            R("addComponent", AddComponent, true);
            R("setSerializedProperty", SetSerialized, true);
            R("deleteGameObject", DeleteGameObject, true);
            R("saveScene", SaveSceneOp, true);
            R("createPrefab", CreatePrefab, true);
        }

        // ================================================================ small helpers

        static D Obj(params object[] kv)
        {
            var d = new D();
            for (int i = 0; i + 1 < kv.Length; i += 2) d[(string)kv[i]] = kv[i + 1];
            return d;
        }
        static string Str(D a, string k, string def = null) => a.TryGetValue(k, out var v) && v is string s ? s : def;
        static int Int(D a, string k, int def) => a.TryGetValue(k, out var v) && v is double d ? (int)d : def;
        static bool Bool(D a, string k, bool def) => a.TryGetValue(k, out var v) && v is bool b ? b : def;
        static D Sub(D a, string k) => a.TryGetValue(k, out var v) ? v as D : null;
        static List<object> Arr(D a, string k) => a.TryGetValue(k, out var v) ? v as List<object> : null;
        static string Trim(string s, int n) => JarvisBridge.Trim(s, n);

        static void Require(bool ok, string code, string msg, object extra = null) { if (!ok) throw new OpException(code, msg, extra); }

        static D Ping(D a) => Obj("pong", true, "protocol", JarvisBridge.ProtocolVersion, "session", JarvisBridge.SessionId, "owned", JarvisBridge.IsOwned);

        // ================================================================ identity

        static string HierarchyPath(Transform t, bool indexed)
        {
            var parts = new List<string>();
            for (var x = t; x != null; x = x.parent)
            {
                string name = x.name;
                if (indexed)
                {
                    int idx = 0;
                    var sibs = SiblingsOf(x);
                    for (int i = 0; i < sibs.Count; i++) { if (sibs[i] == x) break; if (sibs[i].name == x.name) idx++; }
                    name += "#" + idx;
                }
                parts.Add(name);
            }
            parts.Reverse();
            return string.Join("/", parts);
        }

        static List<Transform> SiblingsOf(Transform t)
        {
            var l = new List<Transform>();
            if (t.parent != null) { for (int i = 0; i < t.parent.childCount; i++) l.Add(t.parent.GetChild(i)); }
            else foreach (var r in t.gameObject.scene.GetRootGameObjects()) l.Add(r.transform);
            return l;
        }

        static string GlobalId(Object o)
        {
            try
            {
                var id = GlobalObjectId.GetGlobalObjectIdSlow(o);
                return id.identifierType == 0 ? null : id.ToString();
            }
            catch (Exception) { return null; }
        }

        static D Identity(GameObject go) => Obj(
            "name", go.name, "scene", go.scene.path, "path", HierarchyPath(go.transform, false), "indexedPath", HierarchyPath(go.transform, true),
            "globalId", GlobalId(go), "active", go.activeSelf, "activeInHierarchy", go.activeInHierarchy);

        static IEnumerable<GameObject> AllObjects(Scene s)
        {
            foreach (var root in s.GetRootGameObjects())
                foreach (var t in root.GetComponentsInChildren<Transform>(true)) yield return t.gameObject;
        }

        static IEnumerable<Scene> Loaded()
        {
            for (int i = 0; i < SceneManager.sceneCount; i++) { var s = SceneManager.GetSceneAt(i); if (s.isLoaded) yield return s; }
        }

        static GameObject FindByIndexedPath(string path, string scenePath)
        {
            var parts = path.Split('/');
            foreach (var scene in Loaded())
            {
                if (!string.IsNullOrEmpty(scenePath) && scene.path != scenePath) continue;
                Transform cur = null;
                bool ok = true;
                for (int i = 0; i < parts.Length && ok; i++)
                {
                    var (name, idx) = SplitIndex(parts[i]);
                    IEnumerable<Transform> kids = i == 0 ? scene.GetRootGameObjects().Select(g => g.transform) : Enumerable.Range(0, cur.childCount).Select(c => cur.GetChild(c));
                    var matches = kids.Where(k => k.name == name).ToList();
                    if (matches.Count == 0) { ok = false; break; }
                    if (idx < 0 && matches.Count > 1) throw new OpException("ambiguousTarget", "More than one GameObject matches \"" + parts[i] + "\" at this level; use the indexed path (name#index) or the globalId.", Candidates(matches.Select(m => m.gameObject)));
                    var pick = idx < 0 ? 0 : idx;
                    if (pick >= matches.Count) { ok = false; break; }
                    cur = matches[pick];
                }
                if (ok && cur != null) return cur.gameObject;
            }
            return null;
        }

        static (string, int) SplitIndex(string part)
        {
            int h = part.LastIndexOf('#');
            if (h > 0 && int.TryParse(part.Substring(h + 1), out var n)) return (part.Substring(0, h), n);
            return (part, -1);
        }

        static List<object> Candidates(IEnumerable<GameObject> gos) => gos.Take(10).Select(g => (object)Identity(g)).ToList();

        /// <summary>Resolves a target by globalId, then by (indexed) path. A bare name is NOT a valid mutation target.</summary>
        static GameObject Resolve(D target, bool allowNameOnly = false)
        {
            Require(target != null, "invalidArguments", "A target is required.");
            string gid = Str(target, "globalId"), path = Str(target, "path"), scene = Str(target, "scene"), name = Str(target, "name");
            GameObject byId = null, byPath = null;
            if (!string.IsNullOrEmpty(gid))
            {
                if (GlobalObjectId.TryParse(gid, out var id))
                {
                    var obj = GlobalObjectId.GlobalObjectIdentifierToObjectSlow(id);
                    byId = obj as GameObject;
                    if (byId == null && obj is Component c) byId = c.gameObject;
                }
                Require(byId != null, "targetNotFound", "No GameObject with this globalId exists in the loaded scenes (it may have been deleted or the scene reloaded).");
            }
            if (!string.IsNullOrEmpty(path)) byPath = FindByIndexedPath(path, scene);
            if (byId != null && byPath != null)
                Require(byId == byPath, "identityMismatch", "The globalId and the path refer to different GameObjects.");
            var found = byId ?? byPath;
            if (found != null) return found;
            if (!string.IsNullOrEmpty(path) || !string.IsNullOrEmpty(gid)) throw new OpException("targetNotFound", "The target does not exist.");
            if (!string.IsNullOrEmpty(name))
            {
                Require(allowNameOnly, "ambiguousTarget", "A GameObject must be identified by globalId or path, not by name alone.");
                var matches = Loaded().SelectMany(AllObjects).Where(g => g.name == name).ToList();
                Require(matches.Count > 0, "targetNotFound", "No GameObject is named \"" + name + "\".");
                Require(matches.Count == 1, "ambiguousTarget", matches.Count + " GameObjects are named \"" + name + "\"; identify one by path or globalId.", Candidates(matches));
                return matches[0];
            }
            throw new OpException("invalidArguments", "The target needs a globalId or a path.");
        }

        static Component ResolveComponent(GameObject go, D args)
        {
            string typeName = Str(args, "componentType");
            Require(!string.IsNullOrEmpty(typeName), "invalidArguments", "componentType is required.");
            var comps = go.GetComponents<Component>().Where(c => c != null && (c.GetType().Name == typeName || c.GetType().FullName == typeName)).ToList();
            Require(comps.Count > 0, "componentNotFound", "\"" + go.name + "\" has no " + typeName + " component.");
            int idx = Int(args, "componentIndex", -1);
            if (idx < 0)
                Require(comps.Count == 1, "ambiguousComponent", comps.Count + " " + typeName + " components exist on \"" + go.name + "\"; specify componentIndex.");
            if (idx >= comps.Count) throw new OpException("componentNotFound", "componentIndex is out of range (" + comps.Count + " found).");
            return comps[idx < 0 ? 0 : idx];
        }

        static Type ResolveComponentType(string name)
        {
            Require(!string.IsNullOrEmpty(name) && name.All(ch => char.IsLetterOrDigit(ch) || ch == '_' || ch == '.'), "invalidArguments", "The component type name is not valid.");
            var found = new List<Type>();
            foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
            {
                Type[] types;
                try { types = asm.GetTypes(); } catch (ReflectionTypeLoadException e) { types = e.Types.Where(t => t != null).ToArray(); } catch (Exception) { continue; }
                foreach (var t in types)
                {
                    if (!typeof(Component).IsAssignableFrom(t) || t.IsAbstract || t.IsGenericType || !t.IsPublic) continue;
                    if (t.Namespace != null && t.Namespace.StartsWith("UnityEditor")) continue;
                    if (t.Name == name || t.FullName == name) found.Add(t);
                }
            }
            Require(found.Count > 0, "unknownComponentType", "No component type \"" + name + "\" exists in this project.");
            Require(found.Count == 1, "ambiguousComponentType", found.Count + " component types are named \"" + name + "\": " + string.Join(", ", found.Select(f => f.FullName)) + ". Use the full name.");
            return found[0];
        }

        static Scene SceneFor(string path)
        {
            if (string.IsNullOrEmpty(path)) return SceneManager.GetActiveScene();
            foreach (var s in Loaded()) if (s.path == path) return s;
            throw new OpException("sceneNotLoaded", "The scene \"" + path + "\" is not loaded.");
        }

        static void MarkDirty(Scene s)
        {
            EditorSceneManager.MarkSceneDirty(s);
            SetJarvisDirty(s.path, true);
            JarvisBridge.ForceStatus();
        }

        // ================================================================ project & scene inspection

        static D GetProjectInfo(D a)
        {
            string rp = "Built-in";
            try { var p = UnityEngine.Rendering.GraphicsSettings.currentRenderPipeline; if (p != null) rp = p.GetType().Name; } catch (Exception) { }
            return Obj("unityVersion", Application.unityVersion, "projectName", Path.GetFileName(JarvisBridge.ProjectPath), "productName", Application.productName,
                       "renderPipeline", rp, "batchMode", Application.isBatchMode, "platform", EditorUserBuildSettings.activeBuildTarget.ToString(),
                       "isPlaying", EditorApplication.isPlaying, "isCompiling", EditorApplication.isCompiling, "bridgeVersion", JarvisBridge.BridgeVersion,
                       "session", JarvisBridge.SessionId, "owned", JarvisBridge.IsOwned);
        }

        static D SceneInfo(Scene s) => Obj("path", s.path, "name", s.name, "dirty", s.isDirty, "jarvisDirty", IsJarvisDirty(s.path), "loaded", s.isLoaded, "rootCount", s.rootCount);

        static D ListScenes(D a)
        {
            var loaded = Loaded().Select(s => (object)SceneInfo(s)).ToList();
            var project = AssetDatabase.FindAssets("t:Scene").Select(AssetDatabase.GUIDToAssetPath).Where(p => p.StartsWith("Assets/")).Take(100).Cast<object>().ToList();
            return Obj("loaded", loaded, "inProject", project, "active", SceneManager.GetActiveScene().path);
        }

        static D GetActiveScene(D a) => SceneInfo(SceneManager.GetActiveScene());

        static D OpenScene(D a)
        {
            string path = Str(a, "path");
            Require(!string.IsNullOrEmpty(path) && path.StartsWith("Assets/") && path.EndsWith(".unity") && !path.Contains(".."), "invalidArguments", "path must be a project scene under Assets/.");
            Require(File.Exists(Path.Combine(JarvisBridge.ProjectPath, path)), "sceneNotFound", "The scene does not exist.");
            Require(!EditorApplication.isPlaying, "playModeActive", "Scenes cannot be switched during Play Mode.");
            // Never discard unsaved work: refuse when ANY loaded scene is dirty (re-opening the same scene would discard its edits too).
            foreach (var s in Loaded()) Require(!s.isDirty, "dirtySceneProtected", "Scene \"" + (string.IsNullOrEmpty(s.path) ? s.name : s.path) + "\" has unsaved changes; opening another scene would discard them.");
            var opened = EditorSceneManager.OpenScene(path, Bool(a, "additive", false) ? OpenSceneMode.Additive : OpenSceneMode.Single);
            JarvisBridge.ForceStatus();
            return SceneInfo(opened);
        }

        static D ListRoots(D a)
        {
            var scene = SceneFor(Str(a, "scene"));
            int max = Math.Min(Int(a, "max", 100), MaxObjects);
            var roots = scene.GetRootGameObjects();
            return Obj("scene", scene.path, "total", roots.Length, "truncated", roots.Length > max, "objects", roots.Take(max).Select(g => (object)Identity(g)).ToList());
        }

        static D FindGameObjects(D a)
        {
            string name = Str(a, "name"), comp = Str(a, "componentType");
            int max = Math.Min(Int(a, "max", 20), 50);
            Require(!string.IsNullOrEmpty(name) || !string.IsNullOrEmpty(comp), "invalidArguments", "name or componentType is required.");
            var hits = new List<GameObject>();
            foreach (var s in Loaded())
                foreach (var go in AllObjects(s))
                {
                    if (!string.IsNullOrEmpty(name) && go.name != name) continue;
                    if (!string.IsNullOrEmpty(comp) && !go.GetComponents<Component>().Any(c => c != null && (c.GetType().Name == comp || c.GetType().FullName == comp))) continue;
                    hits.Add(go);
                }
            return Obj("count", hits.Count, "truncated", hits.Count > max, "objects", hits.Take(max).Select(g => (object)Identity(g)).ToList());
        }

        static D PrefabInfo(GameObject go)
        {
            var status = PrefabUtility.GetPrefabInstanceStatus(go);
            string src = null;
            var source = PrefabUtility.GetCorrespondingObjectFromSource(go);
            if (source != null) src = AssetDatabase.GetAssetPath(source);
            return Obj("isPartOfPrefab", PrefabUtility.IsPartOfAnyPrefab(go), "instanceStatus", status.ToString(), "sourceAsset", src);
        }

        static D InspectGameObject(D a)
        {
            var go = Resolve(a.TryGetValue("target", out var t) ? t as D : null, true);
            int depth = Math.Min(Math.Max(Int(a, "depth", 1), 0), MaxDepth);
            int maxChildren = Math.Min(Int(a, "maxChildren", 50), MaxObjects);
            var d = Identity(go);
            d["tag"] = go.tag; d["layer"] = LayerMask.LayerToName(go.layer);
            d["isStatic"] = go.isStatic;
            d["localPosition"] = Vec(go.transform.localPosition); d["localEulerAngles"] = Vec(go.transform.localEulerAngles); d["localScale"] = Vec(go.transform.localScale);
            d["components"] = go.GetComponents<Component>().Where(c => c != null).GroupBy(c => c.GetType()).SelectMany(g => g.Select((c, i) => (object)Obj("type", g.Key.Name, "fullType", g.Key.FullName, "index", i))).ToList();
            d["prefab"] = PrefabInfo(go);
            int count = 0;
            d["children"] = Children(go.transform, depth, maxChildren, ref count);
            d["truncated"] = count >= maxChildren;
            return d;
        }

        static List<object> Children(Transform t, int depth, int max, ref int count)
        {
            var l = new List<object>();
            if (depth <= 0) return l;
            for (int i = 0; i < t.childCount && count < max; i++)
            {
                var c = t.GetChild(i);
                count++;
                var d = Identity(c.gameObject);
                d["childCount"] = c.childCount;
                if (depth > 1) d["children"] = Children(c, depth - 1, max, ref count);
                l.Add(d);
            }
            return l;
        }

        static List<object> Vec(Vector3 v) => new List<object> { (double)v.x, (double)v.y, (double)v.z };

        static D InspectComponents(D a)
        {
            var go = Resolve(a.TryGetValue("target", out var t) ? t as D : null, true);
            var filter = Arr(a, "types")?.OfType<string>().ToHashSet();
            var result = new List<object>();
            foreach (var g in go.GetComponents<Component>().Where(c => c != null).GroupBy(c => c.GetType()))
            {
                if (filter != null && filter.Count > 0 && !filter.Contains(g.Key.Name) && !filter.Contains(g.Key.FullName)) continue;
                int i = 0;
                foreach (var c in g)
                    result.Add(Obj("type", g.Key.Name, "fullType", g.Key.FullName, "index", i++, "properties", Props(c, null, Math.Min(Int(a, "maxProperties", 30), MaxProps))));
            }
            return Obj("target", Identity(go), "components", result);
        }

        static D InspectSerialized(D a)
        {
            var go = Resolve(a.TryGetValue("target", out var t) ? t as D : null, true);
            var comp = ResolveComponent(go, a);
            var paths = Arr(a, "propertyPaths")?.OfType<string>().ToList();
            return Obj("target", Identity(go), "componentType", comp.GetType().Name, "properties", Props(comp, paths, MaxProps));
        }

        static List<object> Props(Component c, List<string> only, int max)
        {
            var list = new List<object>();
            var so = new SerializedObject(c);
            if (only != null && only.Count > 0)
            {
                foreach (var p in only.Take(MaxProps))
                {
                    var sp = so.FindProperty(p);
                    list.Add(sp == null ? Obj("path", p, "exists", false) : PropDesc(sp));
                }
                return list;
            }
            var it = so.GetIterator();
            bool enter = true;
            while (it.NextVisible(enter) && list.Count < max)
            {
                enter = false;
                if (it.propertyPath == "m_Script") continue;
                list.Add(PropDesc(it));
            }
            return list;
        }

        static D PropDesc(SerializedProperty p)
        {
            bool ok = TryRead(p, out var value, out var type);
            var d = Obj("path", p.propertyPath, "exists", true, "type", type, "representable", ok);
            d["value"] = ok ? value : null;
            if (p.propertyType == SerializedPropertyType.Enum) d["enumNames"] = p.enumNames.Cast<object>().ToList();
            return d;
        }

        static bool TryRead(SerializedProperty p, out object v, out string type)
        {
            type = p.propertyType.ToString();
            switch (p.propertyType)
            {
                case SerializedPropertyType.Integer: case SerializedPropertyType.LayerMask: case SerializedPropertyType.ArraySize: case SerializedPropertyType.Character: v = (double)p.longValue; return true;
                case SerializedPropertyType.Boolean: v = p.boolValue; return true;
                case SerializedPropertyType.Float: v = (double)p.doubleValue; return true;
                case SerializedPropertyType.String: v = p.stringValue; return true;
                case SerializedPropertyType.Enum: v = p.enumValueIndex >= 0 && p.enumValueIndex < p.enumNames.Length ? p.enumNames[p.enumValueIndex] : (object)(double)p.enumValueIndex; return true;
                case SerializedPropertyType.Vector2: v = new List<object> { (double)p.vector2Value.x, (double)p.vector2Value.y }; return true;
                case SerializedPropertyType.Vector3: v = new List<object> { (double)p.vector3Value.x, (double)p.vector3Value.y, (double)p.vector3Value.z }; return true;
                case SerializedPropertyType.Vector4: v = new List<object> { (double)p.vector4Value.x, (double)p.vector4Value.y, (double)p.vector4Value.z, (double)p.vector4Value.w }; return true;
                case SerializedPropertyType.Quaternion: v = new List<object> { (double)p.quaternionValue.x, (double)p.quaternionValue.y, (double)p.quaternionValue.z, (double)p.quaternionValue.w }; return true;
                case SerializedPropertyType.Color: v = new List<object> { (double)p.colorValue.r, (double)p.colorValue.g, (double)p.colorValue.b, (double)p.colorValue.a }; return true;
                case SerializedPropertyType.ObjectReference:
                    v = p.objectReferenceValue == null ? null : (object)(AssetDatabase.GetAssetPath(p.objectReferenceValue) is string ap && ap.Length > 0 ? ap : p.objectReferenceValue.name);
                    return true;
                default: v = null; return false;
            }
        }

        static bool Equal(object a, object b)
        {
            if (a == null || b == null) return a == null && b == null;
            if (a is double da && b is double db) return Math.Abs(da - db) < 1e-5;
            if (a is List<object> la && b is List<object> lb) { if (la.Count != lb.Count) return false; for (int i = 0; i < la.Count; i++) if (!Equal(la[i], lb[i])) return false; return true; }
            return a.Equals(b);
        }

        static D SetSerialized(D a)
        {
            var go = Resolve(a.TryGetValue("target", out var t) ? t as D : null);
            var comp = ResolveComponent(go, a);
            string path = Str(a, "propertyPath");
            Require(!string.IsNullOrEmpty(path), "invalidArguments", "propertyPath is required.");
            Require(a.ContainsKey("newValue"), "invalidArguments", "newValue is required.");
            var so = new SerializedObject(comp);
            var p = so.FindProperty(path);
            Require(p != null, "propertyNotFound", "\"" + path + "\" is not a serialized property of " + comp.GetType().Name + ".");
            Require(TryRead(p, out var current, out var type), "propertyNotRepresentable", "Properties of type " + type + " cannot be edited through the bridge.");
            Require(p.propertyType != SerializedPropertyType.ObjectReference, "propertyNotRepresentable", "Object references cannot be edited through the bridge.");
            var expectedOld = a.ContainsKey("expectedOld") ? a["expectedOld"] : null;
            bool hasExpected = a.ContainsKey("expectedOld");
            var newValue = a["newValue"];
            if (Equal(current, newValue)) return Obj("changed", false, "alreadyApplied", true, "value", current, "target", Identity(go));
            if (hasExpected) Require(Equal(current, expectedOld), "expectedValueMismatch", "The current value does not match the expected old value.", Obj("current", current));
            Assign(p, newValue);
            so.ApplyModifiedProperties();
            MarkDirty(go.scene);
            TryRead(so.FindProperty(path), out var after, out _);
            return Obj("changed", true, "alreadyApplied", false, "value", after, "undoRecorded", true, "target", Identity(go));
        }

        static void Assign(SerializedProperty p, object v)
        {
            switch (p.propertyType)
            {
                case SerializedPropertyType.Integer: case SerializedPropertyType.LayerMask: case SerializedPropertyType.Character:
                    Require(v is double di && di == Math.Floor(di), "invalidValue", "An integer is required."); p.longValue = (long)(double)v; break;
                case SerializedPropertyType.Boolean: Require(v is bool, "invalidValue", "A boolean is required."); p.boolValue = (bool)v; break;
                case SerializedPropertyType.Float: Require(v is double, "invalidValue", "A number is required."); p.doubleValue = (double)v; break;
                case SerializedPropertyType.String: Require(v is string, "invalidValue", "A string is required."); p.stringValue = (string)v; break;
                case SerializedPropertyType.Enum:
                    if (v is string name) { int i = Array.IndexOf(p.enumNames, name); Require(i >= 0, "invalidValue", "\"" + name + "\" is not one of: " + string.Join(", ", p.enumNames)); p.enumValueIndex = i; }
                    else { Require(v is double, "invalidValue", "An enum name or index is required."); int i = (int)(double)v; Require(i >= 0 && i < p.enumNames.Length, "invalidValue", "The enum index is out of range."); p.enumValueIndex = i; }
                    break;
                case SerializedPropertyType.Vector2: { var l = Nums(v, 2); p.vector2Value = new Vector2(l[0], l[1]); break; }
                case SerializedPropertyType.Vector3: { var l = Nums(v, 3); p.vector3Value = new Vector3(l[0], l[1], l[2]); break; }
                case SerializedPropertyType.Vector4: { var l = Nums(v, 4); p.vector4Value = new Vector4(l[0], l[1], l[2], l[3]); break; }
                case SerializedPropertyType.Quaternion: { var l = Nums(v, 4); p.quaternionValue = new Quaternion(l[0], l[1], l[2], l[3]); break; }
                case SerializedPropertyType.Color: { var l = Nums(v, 4); p.colorValue = new Color(l[0], l[1], l[2], l[3]); break; }
                default: throw new OpException("propertyNotRepresentable", "This property type cannot be edited.");
            }
        }

        static float[] Nums(object v, int n)
        {
            var l = v as List<object>;
            Require(l != null && l.Count == n && l.All(x => x is double), "invalidValue", "An array of " + n + " numbers is required.");
            return l.Select(x => (float)(double)x).ToArray();
        }

        // ================================================================ bounded mutations

        static D CreateGameObject(D a)
        {
            string name = Str(a, "name");
            Require(!string.IsNullOrEmpty(name) && name.Length <= 80 && !name.Contains("/") && !name.Contains("#"), "invalidArguments", "A valid name (no / or #) is required.");
            var scene = SceneFor(Str(a, "scene"));
            GameObject parent = a.ContainsKey("parent") && a["parent"] is D pd ? Resolve(pd) : null;
            if (parent != null) Require(parent.scene == scene, "invalidArguments", "The parent is in a different scene.");
            if (Bool(a, "ifAbsent", true))
            {
                IEnumerable<Transform> sibs = parent != null ? Enumerable.Range(0, parent.transform.childCount).Select(i => parent.transform.GetChild(i)) : scene.GetRootGameObjects().Select(g => g.transform);
                var existing = sibs.Where(s => s.name == name).ToList();
                if (existing.Count == 1) return Obj("created", false, "alreadyExists", true, "object", Identity(existing[0].gameObject));
                Require(existing.Count == 0, "ambiguousTarget", existing.Count + " siblings already use the name \"" + name + "\".", Candidates(existing.Select(e => e.gameObject)));
            }
            string prim = Str(a, "primitive", "None");
            GameObject go;
            if (prim == "None") go = new GameObject(name);
            else
            {
                Require(Enum.TryParse<PrimitiveType>(prim, out var pt), "invalidArguments", "Unknown primitive \"" + prim + "\".");
                go = GameObject.CreatePrimitive(pt); go.name = name;
            }
            Undo.RegisterCreatedObjectUndo(go, "JARVIS create " + name);
            if (go.scene != scene) SceneManager.MoveGameObjectToScene(go, scene);
            if (parent != null) go.transform.SetParent(parent.transform, false);
            if (a.TryGetValue("position", out var pos)) go.transform.localPosition = ToVec3(pos);
            if (a.TryGetValue("rotation", out var rot)) go.transform.localEulerAngles = ToVec3(rot);
            if (a.TryGetValue("scale", out var sc)) go.transform.localScale = ToVec3(sc);
            MarkDirty(scene);
            return Obj("created", true, "alreadyExists", false, "undoRecorded", true, "object", Identity(go));
        }

        static Vector3 ToVec3(object v) { var n = Nums(v, 3); return new Vector3(n[0], n[1], n[2]); }

        static D AddComponent(D a)
        {
            var go = Resolve(a.TryGetValue("target", out var t) ? t as D : null);
            var type = ResolveComponentType(Str(a, "componentType"));
            if (Bool(a, "ifAbsent", true))
            {
                var existing = go.GetComponents(type);
                if (existing.Length > 0) return Obj("added", false, "alreadyPresent", true, "count", existing.Length, "target", Identity(go));
            }
            var c = Undo.AddComponent(go, type);
            Require(c != null, "addComponentFailed", "Unity refused to add " + type.Name + " to \"" + go.name + "\" (conflicting or disallowed component).");
            MarkDirty(go.scene);
            return Obj("added", true, "alreadyPresent", false, "undoRecorded", true, "count", go.GetComponents(type).Length, "target", Identity(go));
        }

        static D DeleteGameObject(D a)
        {
            var go = Resolve(a.TryGetValue("target", out var t) ? t as D : null);
            var scene = go.scene;
            var identity = Identity(go);
            Undo.DestroyObjectImmediate(go);
            MarkDirty(scene);
            return Obj("deleted", true, "undoRecorded", true, "object", identity);
        }

        static D SaveSceneOp(D a)
        {
            var scene = SceneFor(Str(a, "scene"));
            Require(!string.IsNullOrEmpty(scene.path), "sceneNotSaved", "The scene has no asset path yet.");
            if (!scene.isDirty) return Obj("saved", false, "wasDirty", false, "scene", scene.path);
            bool ok = EditorSceneManager.SaveScene(scene);
            Require(ok, "saveFailed", "Unity could not save the scene.");
            SetJarvisDirty(scene.path, false);
            JarvisBridge.ForceStatus();
            return Obj("saved", true, "wasDirty", true, "scene", scene.path);
        }

        static D CreatePrefab(D a)
        {
            var go = Resolve(a.TryGetValue("target", out var t) ? t as D : null);
            string path = Str(a, "assetPath");
            Require(!string.IsNullOrEmpty(path) && path.StartsWith("Assets/") && path.EndsWith(".prefab") && !path.Contains("..") && !path.Contains("//"), "invalidArguments", "assetPath must be a new .prefab under Assets/.");
            Require(!File.Exists(Path.Combine(JarvisBridge.ProjectPath, path)), "assetExists", "A prefab already exists at that path; the bridge never overwrites assets.");
            Require(!PrefabUtility.IsPartOfAnyPrefab(go), "alreadyPrefab", "The object is already part of a prefab.");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.Combine(JarvisBridge.ProjectPath, path)));
            var prefab = PrefabUtility.SaveAsPrefabAsset(go, path, out bool success);
            Require(success && prefab != null, "prefabFailed", "Unity could not create the prefab.");
            return Obj("created", true, "assetPath", path, "object", Identity(go));
        }

        static D InspectPrefab(D a)
        {
            var go = Resolve(a.TryGetValue("target", out var t) ? t as D : null, true);
            var d = PrefabInfo(go);
            d["target"] = Identity(go);
            if (PrefabUtility.IsPartOfPrefabInstance(go)) d["overrides"] = PrefabUtility.GetObjectOverrides(PrefabUtility.GetOutermostPrefabInstanceRoot(go)).Count;
            return d;
        }

        // ================================================================ console, compilation, play mode

        static D ReadConsole(D a)
        {
            long after = a.TryGetValue("afterSeq", out var s) && s is double sd ? (long)sd : 0;
            int max = Math.Min(Int(a, "max", 100), 200);
            var types = Arr(a, "types")?.OfType<string>().ToHashSet();
            var entries = ConsoleLog.Read(after, max, types, out var last);
            return Obj("entries", entries, "lastSeq", last, "count", entries.Count);
        }

        static D GetCompilation(D a)
        {
            return Obj("isCompiling", EditorApplication.isCompiling, "generation", JarvisBridge.CompileGeneration, "running", JarvisBridge.CompileRunning,
                       "scriptCompilationFailed", EditorUtility.scriptCompilationFailed, "errors", JarvisBridge.CompileErrors.Cast<object>().ToList(),
                       "warnings", JarvisBridge.CompileWarnings, "startedAt", JarvisBridge.CompileStartedAt ?? "", "reloads", JarvisBridge.ReloadCount);
        }

        static D RequestCompilation(D a)
        {
            Require(!EditorApplication.isPlaying, "playModeActive", "Scripts are not recompiled during Play Mode.");
            int before = JarvisBridge.CompileGeneration;
            AssetDatabase.Refresh(ImportAssetOptions.Default);
            CompilationPipeline.RequestScriptCompilation();
            JarvisBridge.ForceStatus();
            return Obj("isCompiling", EditorApplication.isCompiling, "generationBefore", before, "generation", JarvisBridge.CompileGeneration);
        }

        static D GetPlayMode(D a) => Obj("isPlaying", EditorApplication.isPlaying, "isPaused", EditorApplication.isPaused, "willChange", EditorApplication.isPlayingOrWillChangePlaymode,
                                          "state", EditorApplication.isPlaying ? "playing" : EditorApplication.isPlayingOrWillChangePlaymode ? "transition" : "edit");

        static D EnterPlay(D a)
        {
            Require(!EditorApplication.isCompiling, "editorBusy", "Scripts are compiling.");
            Require(!EditorUtility.scriptCompilationFailed, "compileErrors", "The project has script compile errors; Play Mode cannot be entered.");
            if (EditorApplication.isPlaying) return Obj("alreadyPlaying", true);
            EditorApplication.EnterPlaymode();
            JarvisBridge.ForceStatus();
            return Obj("accepted", true);
        }

        static D ExitPlay(D a)
        {
            if (!EditorApplication.isPlaying && !EditorApplication.isPlayingOrWillChangePlaymode) return Obj("alreadyStopped", true);
            EditorApplication.ExitPlaymode();
            JarvisBridge.ForceStatus();
            return Obj("accepted", true);
        }

        static D Shutdown(D a)
        {
            Require(JarvisBridge.IsOwned, "notOwned", "This editor was not started by JARVIS; the bridge never closes an editor it does not own.");
            EditorApplication.delayCall += () => EditorApplication.Exit(0);
            return Obj("accepted", true);
        }
    }
}
