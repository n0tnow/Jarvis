using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Jarvis.Bridge
{
    using D = Dictionary<string, object>;

    /// <summary>
    /// V0.13 — the project-operator operations (scene, hierarchy, prefab, component settings, environment). Same rules as every other operation: typed, bounded, answered
    /// with structured data, no code/menu/shell input anywhere, mutations rejected by the dispatcher itself while Play Mode is active or the editor is busy. Component
    /// settings are WHITELISTED per component kind (the Swift side carries the same table; a unit test keeps them equal).
    /// </summary>
    internal static partial class Ops
    {
        static void RegisterOperator(Action<string, JarvisBridge.Handler, bool> R)
        {
            R("createScene", CreateSceneOp, true);
            R("sceneProfile", SceneProfile, false);
            R("editGameObject", EditGameObject, true);
            R("duplicateGameObject", DuplicateGameObject, true);
            R("removeComponent", RemoveComponent, true);
            R("setObjectReference", SetObjectReference, true);
            R("configureComponent", ConfigureComponent, true);
            R("instantiatePrefab", InstantiatePrefab, true);
            R("prefabOverrides", PrefabOverrides, false);
            R("revertPrefabOverrides", RevertPrefabOverrides, true);
            R("applyPrefabOverrides", ApplyPrefabOverrides, true);
            R("createPrefabVariant", CreatePrefabVariant, true);
            R("unpackPrefab", UnpackPrefab, true);
            R("inspectAsset", InspectAsset, false);
            R("createMaterial", CreateMaterial, true);
            R("setMaterialProperty", SetMaterialProperty, true);
            R("inspectLighting", InspectLighting, false);
            R("setEnvironment", SetEnvironment, true);
            R("createAnimatorController", CreateAnimatorController, true);
            R("editAnimatorController", EditAnimatorController, true);
            R("createAnimationClip", CreateAnimationClip, true);
            R("setModelImporter", SetModelImporter, true);
            R("inspectRuntime", InspectRuntime, false);
            R("captureView", CaptureView, false);
            RegisterInputBase(R);
        }

        // ================================================================ small shared helpers

        static bool Has(D a, string k) => a.ContainsKey(k) && a[k] != null;
        static double Num(D a, string k) { Require(a.TryGetValue(k, out var v) && v is double, "invalidValue", "\"" + k + "\" must be a number."); return (double)a[k]; }
        static float F(D a, string k) => (float)Num(a, k);
        static bool B(D a, string k) { Require(a.TryGetValue(k, out var v) && v is bool, "invalidValue", "\"" + k + "\" must be true or false."); return (bool)a[k]; }
        static string S(D a, string k) { Require(a.TryGetValue(k, out var v) && v is string, "invalidValue", "\"" + k + "\" must be a string."); return (string)a[k]; }

        static Color ColorOf(object v, string name)
        {
            var l = v as List<object>;
            Require(l != null && (l.Count == 3 || l.Count == 4) && l.All(x => x is double), "invalidValue", "\"" + name + "\" must be an array of 3 or 4 numbers (r, g, b[, a]).");
            var n = l.Select(x => (float)(double)x).ToArray();
            return new Color(n[0], n[1], n[2], n.Length == 4 ? n[3] : 1f);
        }
        static List<object> ColorList(Color c) => new List<object> { (double)c.r, (double)c.g, (double)c.b, (double)c.a };

        static T EnumOf<T>(object v, string name) where T : struct
        {
            Require(v is string, "invalidValue", "\"" + name + "\" must be one of: " + string.Join(", ", Enum.GetNames(typeof(T))));
            Require(Enum.TryParse((string)v, true, out T r) && Enum.IsDefined(typeof(T), r), "invalidValue", "\"" + (string)v + "\" is not a valid " + name + ". Use one of: " + string.Join(", ", Enum.GetNames(typeof(T))));
            return r;
        }

        static void NeedKeys(D settings, string kind, params string[] allowed)
        {
            foreach (var k in settings.Keys) Require(allowed.Contains(k), "unknownSetting", "\"" + k + "\" is not a supported " + kind + " setting. Supported: " + string.Join(", ", allowed));
        }

        static bool AssetPathOk(string p, string ext = null)
        {
            if (string.IsNullOrEmpty(p) || p.Length > 240 || !p.StartsWith("Assets/") || p.Contains("..") || p.Contains("//") || p.Contains("\\")) return false;
            if (!p.All(ch => char.IsLetterOrDigit(ch) || " ._-/#()+".IndexOf(ch) >= 0)) return false;
            return ext == null || p.EndsWith(ext, StringComparison.Ordinal);
        }

        static string Abs(string assetPath) => Path.Combine(JarvisBridge.ProjectPath, assetPath);

        /// <summary>"Assets/x.anim" or "Assets/model.fbx::ClipName" (a sub-asset). Never anything outside Assets/.</summary>
        static Object LoadAssetRef(string reference, string what)
        {
            Require(!string.IsNullOrEmpty(reference), "invalidArguments", what + " needs an asset path.");
            string path = reference, sub = null;
            int i = reference.IndexOf("::", StringComparison.Ordinal);
            if (i > 0) { path = reference.Substring(0, i); sub = reference.Substring(i + 2); }
            Require(AssetPathOk(path), "invalidArguments", what + " must be an asset path inside Assets/.");
            Require(File.Exists(Abs(path)) || Directory.Exists(Abs(path)), "assetNotFound", "No asset exists at " + path + ".");
            if (sub == null)
            {
                var main = AssetDatabase.LoadMainAssetAtPath(path);
                Require(main != null, "assetNotFound", "Unity could not load " + path + ".");
                return main;
            }
            var found = AssetDatabase.LoadAllAssetsAtPath(path).Where(o => o != null && o.name == sub && !(o is GameObject && AssetDatabase.IsMainAsset(o))).ToList();
            Require(found.Count > 0, "assetNotFound", "No sub-asset named \"" + sub + "\" exists in " + path + ".");
            Require(found.Count == 1 || found.Select(f => f.GetType()).Distinct().Count() > 1 ? true : true, "ambiguousAsset", "");
            return found[0];
        }

        static string AssetRefOf(Object o)
        {
            if (o == null) return null;
            var p = AssetDatabase.GetAssetPath(o);
            if (string.IsNullOrEmpty(p)) return o.name;
            return AssetDatabase.IsMainAsset(o) ? p : p + "::" + o.name;
        }

        // Components JARVIS changed in a prefab instance (so a later "revert/apply MY overrides" never touches the user's own overrides).
        static string TouchKey(Object o)
        {
            var go = o as GameObject ?? (o as Component)?.gameObject;
            if (go == null) return null;
            return go.scene.path + ":" + HierarchyPath(go.transform, true) + "|" + o.GetType().Name;
        }
        static void NoteTouched(Object o)
        {
            var k = TouchKey(o);
            if (k == null) return;
            var set = SessionState.GetString("Jarvis.Bridge.touched", "").Split('\n').Where(x => x.Length > 0).ToList();
            if (!set.Contains(k)) set.Add(k);
            SessionState.SetString("Jarvis.Bridge.touched", string.Join("\n", set.Skip(Math.Max(0, set.Count - 400))));
        }
        static bool WasTouched(Object o)
        {
            var k = TouchKey(o);
            return k != null && SessionState.GetString("Jarvis.Bridge.touched", "").Split('\n').Contains(k);
        }

        /// <summary>A reference that points at something that no longer exists (a missing asset or object), as opposed to a field that was never assigned.</summary>
        static bool HasDanglingReference(SerializedProperty p)
        {
#if UNITY_6000_5_OR_NEWER
            return p.objectReferenceEntityIdValue != EntityId.None;
#else
            return p.objectReferenceInstanceIDValue != 0;
#endif
        }

        static D Pose(GameObject go)
        {
            var t = go.transform;
            return Obj("localPosition", Vec(t.localPosition), "localEulerAngles", Vec(t.localEulerAngles), "localScale", Vec(t.localScale), "position", Vec(t.position), "eulerAngles", Vec(t.eulerAngles),
                       "parent", t.parent == null ? null : HierarchyPath(t.parent, true), "siblingIndex", t.GetSiblingIndex(), "active", go.activeSelf, "tag", go.tag, "layer", LayerMask.LayerToName(go.layer));
        }

        // ================================================================ scene

        static D CreateSceneOp(D a)
        {
            string path = Str(a, "path");
            Require(AssetPathOk(path, ".unity"), "invalidArguments", "path must be a new .unity scene inside Assets/.");
            Require(!File.Exists(Abs(path)), "assetExists", "A scene already exists at that path; the bridge never overwrites assets.");
            foreach (var s in Loaded()) Require(!s.isDirty, "dirtySceneProtected", "Scene \"" + (string.IsNullOrEmpty(s.path) ? s.name : s.path) + "\" has unsaved changes; creating a scene would discard them.");
            Directory.CreateDirectory(Path.GetDirectoryName(Abs(path)));
            bool empty = Str(a, "template", "default") == "empty";
            var scene = EditorSceneManager.NewScene(empty ? NewSceneSetup.EmptyScene : NewSceneSetup.DefaultGameObjects, NewSceneMode.Single);
            Require(EditorSceneManager.SaveScene(scene, path), "saveFailed", "Unity could not save the new scene.");
            SetJarvisDirty(path, false);
            JarvisBridge.ForceStatus();
            var d = SceneInfo(scene); d["created"] = true; d["template"] = empty ? "empty" : "default";
            return d;
        }

        static D SceneProfile(D a)
        {
            var scene = SceneFor(Str(a, "scene"));
            int max = Math.Min(Math.Max(Int(a, "maxObjects", 2000), 10), 5000);
            var all = AllObjects(scene).Take(max).ToList();
            int cams = 0, lights = 0, audio = 0, anim = 0, rb = 0, col = 0, cc = 0, canv = 0, rend = 0, missing = 0;
            var important = new List<object>();
            var prefabs = new Dictionary<string, int>();
            int missingRefs = 0, scanned = 0;
            foreach (var go in all)
            {
                var comps = go.GetComponents<Component>();
                bool notable = false;
                foreach (var c in comps)
                {
                    if (c == null) { missing++; continue; }
                    if (c is Camera) { cams++; notable = true; }
                    else if (c is Light) { lights++; notable = true; }
                    else if (c is Renderer) rend++;
                    else if (c.GetType().Name == "AudioSource") { audio++; notable = true; }
                    else if (c.GetType().Name == "Animator") { anim++; notable = true; }
                    else if (c is Rigidbody) { rb++; notable = true; }
                    else if (c is CharacterController) { cc++; notable = true; }
                    else if (c is Collider) col++;
                    else if (c.GetType().Name == "Canvas") { canv++; notable = true; }
                    else if (c.GetType().Name.Contains("NetworkObject")) notable = true;
                    if (scanned < 400 && !(c is Transform))
                    {
                        scanned++;
                        try
                        {
                            var it = new SerializedObject(c).GetIterator();
                            bool enter = true;
                            int guard = 0;
                            while (it.NextVisible(enter) && guard++ < 80)
                            {
                                enter = true;
                                if (it.propertyType == SerializedPropertyType.ObjectReference && it.objectReferenceValue == null && HasDanglingReference(it)) missingRefs++;
                            }
                        }
                        catch (Exception) { }
                    }
                }
                if (PrefabUtility.IsOutermostPrefabInstanceRoot(go))
                {
                    var src = AssetDatabase.GetAssetPath(PrefabUtility.GetCorrespondingObjectFromSource(go));
                    if (!string.IsNullOrEmpty(src)) prefabs[src] = prefabs.TryGetValue(src, out var n) ? n + 1 : 1;
                }
                if (notable && important.Count < 40)
                    important.Add(Obj("path", HierarchyPath(go.transform, true), "components", comps.Where(c => c != null && !(c is Transform)).Select(c => (object)c.GetType().Name).Take(8).ToList()));
            }
            var tree = new List<object>();
            foreach (var r in scene.GetRootGameObjects().Take(60))
                tree.Add(Obj("name", r.name, "children", r.transform.childCount, "descendants", r.GetComponentsInChildren<Transform>(true).Length - 1, "active", r.activeSelf));
            var env = Obj("ambientMode", RenderSettings.ambientMode.ToString(), "fog", RenderSettings.fog, "skybox", AssetRefOf(RenderSettings.skybox));
            return Obj("scene", scene.path, "name", scene.name, "dirty", scene.isDirty, "jarvisDirty", IsJarvisDirty(scene.path), "rootCount", scene.rootCount, "objectCount", all.Count, "truncated", all.Count >= max,
                       "cameras", cams, "lights", lights, "audioSources", audio, "animators", anim, "rigidbodies", rb, "colliders", col, "characterControllers", cc, "canvases", canv, "renderers", rend,
                       "missingScripts", missing, "missingReferences", missingRefs,
                       "prefabInstances", prefabs.OrderByDescending(p => p.Value).Take(20).Select(p => (object)Obj("asset", p.Key, "count", p.Value)).ToList(),
                       "important", important, "roots", tree, "environment", env);
        }

        // ================================================================ hierarchy

        static D EditGameObject(D a)
        {
            var go = Resolve(Sub(a, "target"));                 // resolved ONCE: a rename or a move changes the path the second pass would look up
            var first = EditGameObjectCore(go, a);
            var second = EditGameObjectCore(go, a);             // read-back by idempotence: the same edit again must change nothing
            first["verified"] = !(second["changed"] is bool c2 && c2);
            return first;
        }

        static D EditGameObjectCore(GameObject go, D a)
        {
            var changed = new List<object>();
            var t = go.transform;
            bool world = Str(a, "space", "local") == "world";
            if (Has(a, "name"))
            {
                string n = S(a, "name");
                Require(n.Length > 0 && n.Length <= 80 && !n.Contains("/") && !n.Contains("#"), "invalidArguments", "A valid name (no / or #) is required.");
                if (go.name != n) { Undo.RecordObject(go, "JARVIS rename"); go.name = n; changed.Add("name"); }
            }
            if (Has(a, "active"))
            {
                bool v = B(a, "active");
                if (go.activeSelf != v) { Undo.RecordObject(go, "JARVIS set active"); go.SetActive(v); changed.Add("active"); }
            }
            if (a.ContainsKey("parent"))
            {
                var pd = a["parent"] as D;
                Transform np = null;
                if (pd != null) { var p = Resolve(pd); Require(p.scene == go.scene, "invalidArguments", "The new parent is in a different scene."); Require(!p.transform.IsChildOf(t), "invalidArguments", "An object cannot become a child of itself or of one of its descendants."); np = p.transform; }
                if (t.parent != np) { Undo.SetTransformParent(t, np, "JARVIS reparent"); changed.Add("parent"); }
            }
            if (Has(a, "siblingIndex"))
            {
                int idx = (int)Num(a, "siblingIndex");
                int count = t.parent != null ? t.parent.childCount : go.scene.rootCount;
                Require(idx >= 0 && idx < count, "invalidArguments", "siblingIndex must be between 0 and " + (count - 1) + ".");
                if (t.GetSiblingIndex() != idx) { Undo.RegisterFullObjectHierarchyUndo(t.parent != null ? t.parent.gameObject : go, "JARVIS reorder"); t.SetSiblingIndex(idx); changed.Add("siblingIndex"); }
            }
            if (Has(a, "position")) { var v = ToVec3(a["position"]); var cur = world ? t.position : t.localPosition; if ((cur - v).sqrMagnitude > 1e-8f) { Undo.RecordObject(t, "JARVIS move"); if (world) t.position = v; else t.localPosition = v; changed.Add("position"); } }
            if (Has(a, "rotation")) { var v = ToVec3(a["rotation"]); var cur = world ? t.rotation : t.localRotation; if (Quaternion.Angle(cur, Quaternion.Euler(v)) > 0.001f) { Undo.RecordObject(t, "JARVIS rotate"); if (world) t.eulerAngles = v; else t.localEulerAngles = v; changed.Add("rotation"); } }
            if (Has(a, "scale")) { var v = ToVec3(a["scale"]); if ((t.localScale - v).sqrMagnitude > 1e-8f) { Undo.RecordObject(t, "JARVIS scale"); t.localScale = v; changed.Add("scale"); } }
            if (Has(a, "tag"))
            {
                string tag = S(a, "tag");
                Require(UnityEditorInternalTags().Contains(tag), "unknownTag", "The tag \"" + tag + "\" does not exist in this project. Existing tags: " + string.Join(", ", UnityEditorInternalTags()));
                if (go.tag != tag) { Undo.RecordObject(go, "JARVIS tag"); go.tag = tag; changed.Add("tag"); }
            }
            if (Has(a, "layer"))
            {
                int layer = LayerMask.NameToLayer(S(a, "layer"));
                Require(layer >= 0, "unknownLayer", "The layer \"" + S(a, "layer") + "\" does not exist in this project.");
                if (go.layer != layer) { Undo.RecordObject(go, "JARVIS layer"); go.layer = layer; changed.Add("layer"); }
            }
            if (Has(a, "isStatic")) { bool v = B(a, "isStatic"); if (go.isStatic != v) { Undo.RecordObject(go, "JARVIS static"); go.isStatic = v; changed.Add("isStatic"); } }
            if (PrefabUtility.IsPartOfPrefabInstance(go)) NoteTouched(t);
            if (changed.Count > 0) MarkDirty(go.scene);
            return Obj("changed", changed.Count > 0, "fields", changed, "object", Identity(go), "after", Pose(go), "undoRecorded", true);
        }

        static IEnumerable<string> UnityEditorInternalTags() => UnityEditorInternal.InternalEditorUtility.tags;

        static D DuplicateGameObject(D a)
        {
            var go = Resolve(Sub(a, "target"));
            Require(go.GetComponentsInChildren<Transform>(true).Length <= 200, "tooLarge", "The object has more than 200 descendants; duplicating it is refused.");
            var copy = Object.Instantiate(go, go.transform.parent);
            Undo.RegisterCreatedObjectUndo(copy, "JARVIS duplicate " + go.name);
            copy.transform.SetSiblingIndex(go.transform.GetSiblingIndex() + 1);
            string n = Str(a, "name");
            if (!string.IsNullOrEmpty(n)) { Require(n.Length <= 80 && !n.Contains("/") && !n.Contains("#"), "invalidArguments", "A valid name (no / or #) is required."); copy.name = n; }
            else copy.name = go.name + " (copy)";
            if (go.scene != copy.scene) SceneManager.MoveGameObjectToScene(copy, go.scene);
            MarkDirty(go.scene);
            return Obj("created", true, "source", Identity(go), "object", Identity(copy), "undoRecorded", true);
        }

        static D RemoveComponent(D a)
        {
            var go = Resolve(Sub(a, "target"));
            var comp = ResolveComponent(go, a);
            Require(!(comp is Transform), "refused", "A Transform cannot be removed.");
            var type = comp.GetType().Name;
            Undo.DestroyObjectImmediate(comp);
            MarkDirty(go.scene);
            return Obj("removed", true, "componentType", type, "target", Identity(go), "undoRecorded", true);
        }

        static D SetObjectReference(D a)
        {
            var go = Resolve(Sub(a, "target"));
            var comp = ResolveComponent(go, a);
            string path = Str(a, "propertyPath");
            Require(!string.IsNullOrEmpty(path), "invalidArguments", "propertyPath is required.");
            var so = new SerializedObject(comp);
            var p = so.FindProperty(path);
            Require(p != null, "propertyNotFound", "\"" + path + "\" is not a serialized property of " + comp.GetType().Name + ".");
            Require(p.propertyType == SerializedPropertyType.ObjectReference, "notAReference", "\"" + path + "\" is not an object reference (it is " + p.propertyType + ").");
            string expected = p.type.StartsWith("PPtr<$") ? p.type.Substring(6).TrimEnd('>') : null;
            Object asset = null;
            if (a.TryGetValue("assetPath", out var ap) && ap is string aps && aps.Length > 0)
            {
                asset = LoadAssetRef(aps, "assetPath");
                if (expected != null)
                {
                    bool ok = false;
                    for (var tt = asset.GetType(); tt != null && !ok; tt = tt.BaseType) ok = tt.Name == expected;
                    // a prefab asset is a GameObject; a component field accepts the component of that prefab: only exact-or-derived types are allowed here
                    Require(ok, "typeMismatch", "\"" + path + "\" expects a " + expected + " but " + aps + " is a " + asset.GetType().Name + ".");
                }
            }
            if (p.objectReferenceValue == asset) return Obj("changed", false, "alreadyApplied", true, "value", AssetRefOf(asset), "target", Identity(go));
            var before = AssetRefOf(p.objectReferenceValue);
            p.objectReferenceValue = asset;
            so.ApplyModifiedProperties();
            if (PrefabUtility.IsPartOfPrefabInstance(go)) NoteTouched(comp);
            MarkDirty(go.scene);
            return Obj("changed", true, "alreadyApplied", false, "before", before, "value", AssetRefOf(new SerializedObject(comp).FindProperty(path).objectReferenceValue), "target", Identity(go), "undoRecorded", true);
        }

        // ================================================================ component settings (whitelisted per kind)

        static D ConfigureComponent(D a)
        {
            var go = Resolve(Sub(a, "target"));
            string kind = Str(a, "kind");
            var settings = Sub(a, "settings");
            Require(settings != null && settings.Count > 0, "invalidArguments", "settings are required.");
            var before = new D();
            var applied = new D();
            var comp = ApplyKind(go, kind, settings, before, applied);
            if (PrefabUtility.IsPartOfPrefabInstance(go)) NoteTouched(comp);
            bool changed = applied.Count > 0;
            if (changed) { EditorUtility.SetDirty(comp); MarkDirty(go.scene); }
            // Read-back by idempotence: applying the same settings again must change nothing, otherwise the first pass did not stick.
            var again = new D();
            ApplyKind(go, kind, settings, new D(), again);
            return Obj("changed", changed, "alreadyApplied", !changed, "verified", again.Count == 0, "kind", kind, "before", before, "applied", applied, "target", Identity(go), "undoRecorded", true);
        }

        static Component ApplyKind(GameObject go, string kind, D settings, D before, D applied)
        {
            switch (kind)
            {
                case "light": return ConfigureLight(go, settings, before, applied);
                case "camera": return ConfigureCamera(go, settings, before, applied);
                case "renderer": return ConfigureRenderer(go, settings, before, applied);
                case "rigidbody": return ConfigureRigidbody(go, settings, before, applied);
                case "collider": return ConfigureCollider(go, settings, before, applied);
                case "characterController": return ConfigureCharacterController(go, settings, before, applied);
                case "audioSource": return ConfigureAudioSource(go, settings, before, applied);
                case "animator": return ConfigureAnimator(go, settings, before, applied);
                case "canvas": return ConfigureCanvas(go, settings, before, applied);
                case "rectTransform": return ConfigureRectTransform(go, settings, before, applied);
                default: throw new OpException("unknownKind", "\"" + kind + "\" is not a supported component kind. Supported: " + string.Join(", ", ComponentKinds));
            }
        }

        // The wire contract: Swift (UnityComponentSchema) carries the same table; a unit test compares the two.
        public static readonly string[] ComponentKinds = { "light", "camera", "renderer", "rigidbody", "collider", "characterController", "audioSource", "animator", "canvas", "rectTransform" };

        static T Need<T>(GameObject go, string kind) where T : Component
        {
            var c = go.GetComponent<T>();
            Require(c != null, "componentNotFound", "\"" + go.name + "\" has no " + kind + " component.");
            return c;
        }

        /// <summary>Records `before` and, when the value really changes, `applied` (idempotent: an equal value changes nothing).</summary>
        static void Track<TV>(string key, TV current, TV wanted, D before, D applied, Action set, Func<TV, object> show = null, Func<TV, TV, bool> same = null)
        {
            bool eq = same != null ? same(current, wanted) : EqualityComparer<TV>.Default.Equals(current, wanted);
            if (eq) return;
            before[key] = show != null ? show(current) : (object)current;
            set();
            applied[key] = show != null ? show(wanted) : (object)wanted;
        }
        static bool Near(float x, float y) => Math.Abs(x - y) < 1e-4f;
        static object Show(float f) => (double)f;

        static Component ConfigureLight(GameObject go, D s, D before, D applied)
        {
            NeedKeys(s, "light", "type", "intensity", "range", "spotAngle", "innerSpotAngle", "color", "shadows", "shadowStrength", "enabled", "bounceIntensity", "colorTemperature", "useColorTemperature");
            var c = Need<Light>(go, "Light");
            Undo.RecordObject(c, "JARVIS configure light");
            if (s.ContainsKey("type")) { var v = EnumOf<LightType>(s["type"], "light type"); Track("type", c.type, v, before, applied, () => c.type = v, x => x.ToString()); }
            if (s.ContainsKey("intensity")) { var v = F(s, "intensity"); Require(v >= 0 && v <= 100000, "invalidValue", "intensity must be between 0 and 100000."); Track("intensity", c.intensity, v, before, applied, () => c.intensity = v, Show, Near); }
            if (s.ContainsKey("range")) { var v = F(s, "range"); Require(v > 0 && v <= 100000, "invalidValue", "range must be greater than 0."); Track("range", c.range, v, before, applied, () => c.range = v, Show, Near); }
            if (s.ContainsKey("spotAngle")) { var v = F(s, "spotAngle"); Require(v >= 1 && v <= 179, "invalidValue", "spotAngle must be between 1 and 179."); Track("spotAngle", c.spotAngle, v, before, applied, () => c.spotAngle = v, Show, Near); }
            if (s.ContainsKey("innerSpotAngle")) { var v = F(s, "innerSpotAngle"); Require(v >= 1 && v <= 179, "invalidValue", "innerSpotAngle must be between 1 and 179."); Track("innerSpotAngle", c.innerSpotAngle, v, before, applied, () => c.innerSpotAngle = v, Show, Near); }
            if (s.ContainsKey("color")) { var v = ColorOf(s["color"], "color"); Track("color", c.color, v, before, applied, () => c.color = v, ColorList2, (x, y) => Near(x.r, y.r) && Near(x.g, y.g) && Near(x.b, y.b) && Near(x.a, y.a)); }
            if (s.ContainsKey("shadows")) { var v = EnumOf<LightShadows>(s["shadows"], "shadows"); Track("shadows", c.shadows, v, before, applied, () => c.shadows = v, x => x.ToString()); }
            if (s.ContainsKey("shadowStrength")) { var v = F(s, "shadowStrength"); Require(v >= 0 && v <= 1, "invalidValue", "shadowStrength must be between 0 and 1."); Track("shadowStrength", c.shadowStrength, v, before, applied, () => c.shadowStrength = v, Show, Near); }
            if (s.ContainsKey("enabled")) { var v = B(s, "enabled"); Track("enabled", c.enabled, v, before, applied, () => c.enabled = v); }
            if (s.ContainsKey("bounceIntensity")) { var v = F(s, "bounceIntensity"); Require(v >= 0 && v <= 8, "invalidValue", "bounceIntensity must be between 0 and 8."); Track("bounceIntensity", c.bounceIntensity, v, before, applied, () => c.bounceIntensity = v, Show, Near); }
            if (s.ContainsKey("useColorTemperature")) { var v = B(s, "useColorTemperature"); Track("useColorTemperature", c.useColorTemperature, v, before, applied, () => c.useColorTemperature = v); }
            if (s.ContainsKey("colorTemperature")) { var v = F(s, "colorTemperature"); Require(v >= 1000 && v <= 20000, "invalidValue", "colorTemperature must be between 1000 and 20000."); Track("colorTemperature", c.colorTemperature, v, before, applied, () => c.colorTemperature = v, Show, Near); }
            return c;
        }
        static object ColorList2(Color c) => ColorList(c);

        static Component ConfigureCamera(GameObject go, D s, D before, D applied)
        {
            NeedKeys(s, "camera", "fieldOfView", "nearClipPlane", "farClipPlane", "orthographic", "orthographicSize", "clearFlags", "backgroundColor", "depth", "enabled");
            var c = Need<Camera>(go, "Camera");
            Undo.RecordObject(c, "JARVIS configure camera");
            if (s.ContainsKey("fieldOfView")) { var v = F(s, "fieldOfView"); Require(v >= 1 && v <= 179, "invalidValue", "fieldOfView must be between 1 and 179."); Track("fieldOfView", c.fieldOfView, v, before, applied, () => c.fieldOfView = v, Show, Near); }
            if (s.ContainsKey("nearClipPlane")) { var v = F(s, "nearClipPlane"); Require(v >= 0.01f && v < c.farClipPlane, "invalidValue", "nearClipPlane must be at least 0.01 and smaller than farClipPlane."); Track("nearClipPlane", c.nearClipPlane, v, before, applied, () => c.nearClipPlane = v, Show, Near); }
            if (s.ContainsKey("farClipPlane")) { var v = F(s, "farClipPlane"); Require(v > c.nearClipPlane && v <= 1000000, "invalidValue", "farClipPlane must be larger than nearClipPlane."); Track("farClipPlane", c.farClipPlane, v, before, applied, () => c.farClipPlane = v, Show, Near); }
            if (s.ContainsKey("orthographic")) { var v = B(s, "orthographic"); Track("orthographic", c.orthographic, v, before, applied, () => c.orthographic = v); }
            if (s.ContainsKey("orthographicSize")) { var v = F(s, "orthographicSize"); Require(v > 0 && v <= 100000, "invalidValue", "orthographicSize must be greater than 0."); Track("orthographicSize", c.orthographicSize, v, before, applied, () => c.orthographicSize = v, Show, Near); }
            if (s.ContainsKey("clearFlags")) { var v = EnumOf<CameraClearFlags>(s["clearFlags"], "clearFlags"); Track("clearFlags", c.clearFlags, v, before, applied, () => c.clearFlags = v, x => x.ToString()); }
            if (s.ContainsKey("backgroundColor")) { var v = ColorOf(s["backgroundColor"], "backgroundColor"); Track("backgroundColor", c.backgroundColor, v, before, applied, () => c.backgroundColor = v, ColorList2, (x, y) => Near(x.r, y.r) && Near(x.g, y.g) && Near(x.b, y.b) && Near(x.a, y.a)); }
            if (s.ContainsKey("depth")) { var v = F(s, "depth"); Track("depth", c.depth, v, before, applied, () => c.depth = v, Show, Near); }
            if (s.ContainsKey("enabled")) { var v = B(s, "enabled"); Track("enabled", c.enabled, v, before, applied, () => c.enabled = v); }
            return c;
        }

        static Component ConfigureRenderer(GameObject go, D s, D before, D applied)
        {
            NeedKeys(s, "renderer", "material", "materialIndex", "enabled", "castShadows", "receiveShadows");
            var c = Need<Renderer>(go, "Renderer");
            Undo.RecordObject(c, "JARVIS configure renderer");
            if (s.ContainsKey("material"))
            {
                int idx = s.ContainsKey("materialIndex") ? (int)Num(s, "materialIndex") : 0;
                var mats = c.sharedMaterials;
                Require(idx >= 0 && idx < mats.Length, "invalidValue", "materialIndex must be between 0 and " + (mats.Length - 1) + ".");
                var m = LoadAssetRef(S(s, "material"), "material") as Material;
                Require(m != null, "typeMismatch", "The asset is not a Material.");
                if (mats[idx] != m) { before["material"] = AssetRefOf(mats[idx]); mats[idx] = m; c.sharedMaterials = mats; applied["material"] = AssetRefOf(m); }
            }
            if (s.ContainsKey("enabled")) { var v = B(s, "enabled"); Track("enabled", c.enabled, v, before, applied, () => c.enabled = v); }
            if (s.ContainsKey("castShadows")) { var v = EnumOf<UnityEngine.Rendering.ShadowCastingMode>(s["castShadows"], "castShadows"); Track("castShadows", c.shadowCastingMode, v, before, applied, () => c.shadowCastingMode = v, x => x.ToString()); }
            if (s.ContainsKey("receiveShadows")) { var v = B(s, "receiveShadows"); Track("receiveShadows", c.receiveShadows, v, before, applied, () => c.receiveShadows = v); }
            return c;
        }

        static Component ConfigureRigidbody(GameObject go, D s, D before, D applied)
        {
#if JARVIS_PHYSICS
            NeedKeys(s, "rigidbody", "mass", "linearDamping", "angularDamping", "useGravity", "isKinematic", "constraints", "interpolation", "collisionDetectionMode");
            var c = Need<Rigidbody>(go, "Rigidbody");
            Undo.RecordObject(c, "JARVIS configure rigidbody");
            if (s.ContainsKey("mass")) { var v = F(s, "mass"); Require(v > 0 && v <= 1000000, "invalidValue", "mass must be greater than 0."); Track("mass", c.mass, v, before, applied, () => c.mass = v, Show, Near); }
            if (s.ContainsKey("linearDamping")) { var v = F(s, "linearDamping"); Require(v >= 0 && v <= 1000000, "invalidValue", "linearDamping must not be negative."); Track("linearDamping", c.linearDamping, v, before, applied, () => c.linearDamping = v, Show, Near); }
            if (s.ContainsKey("angularDamping")) { var v = F(s, "angularDamping"); Require(v >= 0 && v <= 1000000, "invalidValue", "angularDamping must not be negative."); Track("angularDamping", c.angularDamping, v, before, applied, () => c.angularDamping = v, Show, Near); }
            if (s.ContainsKey("useGravity")) { var v = B(s, "useGravity"); Track("useGravity", c.useGravity, v, before, applied, () => c.useGravity = v); }
            if (s.ContainsKey("isKinematic")) { var v = B(s, "isKinematic"); Track("isKinematic", c.isKinematic, v, before, applied, () => c.isKinematic = v); }
            if (s.ContainsKey("interpolation")) { var v = EnumOf<RigidbodyInterpolation>(s["interpolation"], "interpolation"); Track("interpolation", c.interpolation, v, before, applied, () => c.interpolation = v, x => x.ToString()); }
            if (s.ContainsKey("collisionDetectionMode")) { var v = EnumOf<CollisionDetectionMode>(s["collisionDetectionMode"], "collisionDetectionMode"); Track("collisionDetectionMode", c.collisionDetectionMode, v, before, applied, () => c.collisionDetectionMode = v, x => x.ToString()); }
            if (s.ContainsKey("constraints"))
            {
                var l = s["constraints"] as List<object>;
                Require(l != null && l.All(x => x is string), "invalidValue", "constraints must be an array of names: " + string.Join(", ", Enum.GetNames(typeof(RigidbodyConstraints))));
                RigidbodyConstraints v = RigidbodyConstraints.None;
                foreach (var n in l.Cast<string>()) v |= EnumOf<RigidbodyConstraints>(n, "constraint");
                Track("constraints", c.constraints, v, before, applied, () => c.constraints = v, x => x.ToString());
            }
            return c;
#else
            throw new OpException("moduleMissing", "The Physics module is not enabled in this project.");
#endif
        }

        static Component ConfigureCollider(GameObject go, D s, D before, D applied)
        {
#if JARVIS_PHYSICS
            NeedKeys(s, "collider", "enabled", "isTrigger", "center", "size", "radius", "height");
            var c = Need<Collider>(go, "Collider");
            Undo.RecordObject(c, "JARVIS configure collider");
            if (s.ContainsKey("enabled")) { var v = B(s, "enabled"); Track("enabled", c.enabled, v, before, applied, () => c.enabled = v); }
            if (s.ContainsKey("isTrigger")) { var v = B(s, "isTrigger"); Track("isTrigger", c.isTrigger, v, before, applied, () => c.isTrigger = v); }
            Func<Vector3, Vector3, bool> sv = (x, y) => (x - y).sqrMagnitude < 1e-8f;
            Func<Vector3, object> shv = x => Vec(x);
            if (s.ContainsKey("center"))
            {
                var v = ToVec3(s["center"]);
                if (c is BoxCollider bc) Track("center", bc.center, v, before, applied, () => bc.center = v, shv, sv);
                else if (c is SphereCollider sc) Track("center", sc.center, v, before, applied, () => sc.center = v, shv, sv);
                else if (c is CapsuleCollider cc) Track("center", cc.center, v, before, applied, () => cc.center = v, shv, sv);
                else throw new OpException("settingNotApplicable", "center does not apply to a " + c.GetType().Name + ".");
            }
            if (s.ContainsKey("size")) { var v = ToVec3(s["size"]); var bc = c as BoxCollider; Require(bc != null, "settingNotApplicable", "size only applies to a BoxCollider."); Require(v.x > 0 && v.y > 0 && v.z > 0, "invalidValue", "size must be positive."); Track("size", bc.size, v, before, applied, () => bc.size = v, shv, sv); }
            if (s.ContainsKey("radius"))
            {
                var v = F(s, "radius"); Require(v > 0, "invalidValue", "radius must be positive.");
                if (c is SphereCollider sc) Track("radius", sc.radius, v, before, applied, () => sc.radius = v, Show, Near);
                else if (c is CapsuleCollider cc) Track("radius", cc.radius, v, before, applied, () => cc.radius = v, Show, Near);
                else throw new OpException("settingNotApplicable", "radius does not apply to a " + c.GetType().Name + ".");
            }
            if (s.ContainsKey("height")) { var v = F(s, "height"); var cc = c as CapsuleCollider; Require(cc != null, "settingNotApplicable", "height only applies to a CapsuleCollider."); Require(v > 0, "invalidValue", "height must be positive."); Track("height", cc.height, v, before, applied, () => cc.height = v, Show, Near); }
            return c;
#else
            throw new OpException("moduleMissing", "The Physics module is not enabled in this project.");
#endif
        }

        static Component ConfigureCharacterController(GameObject go, D s, D before, D applied)
        {
#if JARVIS_PHYSICS
            NeedKeys(s, "characterController", "height", "radius", "center", "slopeLimit", "stepOffset", "skinWidth", "minMoveDistance");
            var c = Need<CharacterController>(go, "CharacterController");
            Undo.RecordObject(c, "JARVIS configure character controller");
            if (s.ContainsKey("height")) { var v = F(s, "height"); Require(v > 0, "invalidValue", "height must be positive."); Track("height", c.height, v, before, applied, () => c.height = v, Show, Near); }
            if (s.ContainsKey("radius")) { var v = F(s, "radius"); Require(v > 0, "invalidValue", "radius must be positive."); Track("radius", c.radius, v, before, applied, () => c.radius = v, Show, Near); }
            if (s.ContainsKey("center")) { var v = ToVec3(s["center"]); Track("center", c.center, v, before, applied, () => c.center = v, x => Vec(x), (x, y) => (x - y).sqrMagnitude < 1e-8f); }
            if (s.ContainsKey("slopeLimit")) { var v = F(s, "slopeLimit"); Require(v >= 0 && v <= 90, "invalidValue", "slopeLimit must be between 0 and 90."); Track("slopeLimit", c.slopeLimit, v, before, applied, () => c.slopeLimit = v, Show, Near); }
            if (s.ContainsKey("stepOffset")) { var v = F(s, "stepOffset"); Require(v >= 0, "invalidValue", "stepOffset must not be negative."); Track("stepOffset", c.stepOffset, v, before, applied, () => c.stepOffset = v, Show, Near); }
            if (s.ContainsKey("skinWidth")) { var v = F(s, "skinWidth"); Require(v >= 0.0001f, "invalidValue", "skinWidth must be positive."); Track("skinWidth", c.skinWidth, v, before, applied, () => c.skinWidth = v, Show, Near); }
            if (s.ContainsKey("minMoveDistance")) { var v = F(s, "minMoveDistance"); Require(v >= 0, "invalidValue", "minMoveDistance must not be negative."); Track("minMoveDistance", c.minMoveDistance, v, before, applied, () => c.minMoveDistance = v, Show, Near); }
            return c;
#else
            throw new OpException("moduleMissing", "The Physics module is not enabled in this project.");
#endif
        }

        static Component ConfigureAudioSource(GameObject go, D s, D before, D applied)
        {
#if JARVIS_AUDIO
            NeedKeys(s, "audioSource", "clip", "volume", "pitch", "loop", "playOnAwake", "spatialBlend", "minDistance", "maxDistance", "rolloffMode", "mute", "priority", "dopplerLevel", "spread", "outputMixerGroup");
            var c = Need<AudioSource>(go, "AudioSource");
            Undo.RecordObject(c, "JARVIS configure audio source");
            if (s.ContainsKey("clip"))
            {
                Object clip = null;
                if (s["clip"] is string cs && cs.Length > 0) { clip = LoadAssetRef(cs, "clip"); Require(clip is AudioClip, "typeMismatch", "The asset is not an AudioClip."); }
                if (c.clip != (AudioClip)clip) { before["clip"] = AssetRefOf(c.clip); c.clip = (AudioClip)clip; applied["clip"] = AssetRefOf(clip); }
            }
            if (s.ContainsKey("volume")) { var v = F(s, "volume"); Require(v >= 0 && v <= 1, "invalidValue", "volume must be between 0 and 1."); Track("volume", c.volume, v, before, applied, () => c.volume = v, Show, Near); }
            if (s.ContainsKey("pitch")) { var v = F(s, "pitch"); Require(v >= -3 && v <= 3, "invalidValue", "pitch must be between -3 and 3."); Track("pitch", c.pitch, v, before, applied, () => c.pitch = v, Show, Near); }
            if (s.ContainsKey("loop")) { var v = B(s, "loop"); Track("loop", c.loop, v, before, applied, () => c.loop = v); }
            if (s.ContainsKey("playOnAwake")) { var v = B(s, "playOnAwake"); Track("playOnAwake", c.playOnAwake, v, before, applied, () => c.playOnAwake = v); }
            if (s.ContainsKey("mute")) { var v = B(s, "mute"); Track("mute", c.mute, v, before, applied, () => c.mute = v); }
            if (s.ContainsKey("spatialBlend")) { var v = F(s, "spatialBlend"); Require(v >= 0 && v <= 1, "invalidValue", "spatialBlend must be between 0 (2D) and 1 (3D)."); Track("spatialBlend", c.spatialBlend, v, before, applied, () => c.spatialBlend = v, Show, Near); }
            if (s.ContainsKey("minDistance")) { var v = F(s, "minDistance"); Require(v >= 0 && v <= c.maxDistance, "invalidValue", "minDistance must be between 0 and maxDistance."); Track("minDistance", c.minDistance, v, before, applied, () => c.minDistance = v, Show, Near); }
            if (s.ContainsKey("maxDistance")) { var v = F(s, "maxDistance"); Require(v > c.minDistance && v <= 1000000, "invalidValue", "maxDistance must be larger than minDistance."); Track("maxDistance", c.maxDistance, v, before, applied, () => c.maxDistance = v, Show, Near); }
            if (s.ContainsKey("rolloffMode")) { var v = EnumOf<AudioRolloffMode>(s["rolloffMode"], "rolloffMode"); Track("rolloffMode", c.rolloffMode, v, before, applied, () => c.rolloffMode = v, x => x.ToString()); }
            if (s.ContainsKey("priority")) { var v = (int)Num(s, "priority"); Require(v >= 0 && v <= 256, "invalidValue", "priority must be between 0 and 256."); Track("priority", c.priority, v, before, applied, () => c.priority = v); }
            if (s.ContainsKey("dopplerLevel")) { var v = F(s, "dopplerLevel"); Require(v >= 0 && v <= 5, "invalidValue", "dopplerLevel must be between 0 and 5."); Track("dopplerLevel", c.dopplerLevel, v, before, applied, () => c.dopplerLevel = v, Show, Near); }
            if (s.ContainsKey("spread")) { var v = F(s, "spread"); Require(v >= 0 && v <= 360, "invalidValue", "spread must be between 0 and 360."); Track("spread", c.spread, v, before, applied, () => c.spread = v, Show, Near); }
            if (s.ContainsKey("outputMixerGroup"))
            {
                UnityEngine.Audio.AudioMixerGroup g = null;
                if (s["outputMixerGroup"] is string gs && gs.Length > 0) { var o = LoadAssetRef(gs, "outputMixerGroup"); g = o as UnityEngine.Audio.AudioMixerGroup; Require(g != null, "typeMismatch", "The asset is not an AudioMixerGroup. Use Assets/…mixer::GroupName."); }
                if (c.outputAudioMixerGroup != g) { before["outputMixerGroup"] = AssetRefOf(c.outputAudioMixerGroup); c.outputAudioMixerGroup = g; applied["outputMixerGroup"] = AssetRefOf(g); }
            }
            return c;
#else
            throw new OpException("moduleMissing", "The Audio module is not enabled in this project.");
#endif
        }

        static Component ConfigureAnimator(GameObject go, D s, D before, D applied)
        {
#if JARVIS_ANIMATION
            NeedKeys(s, "animator", "controller", "avatar", "applyRootMotion", "updateMode", "cullingMode", "speed", "enabled");
            var c = Need<Animator>(go, "Animator");
            Undo.RecordObject(c, "JARVIS configure animator");
            if (s.ContainsKey("controller"))
            {
                RuntimeAnimatorController rc = null;
                if (s["controller"] is string cs && cs.Length > 0) { var o = LoadAssetRef(cs, "controller"); rc = o as RuntimeAnimatorController; Require(rc != null, "typeMismatch", "The asset is not an Animator Controller."); }
                if (c.runtimeAnimatorController != rc) { before["controller"] = AssetRefOf(c.runtimeAnimatorController); c.runtimeAnimatorController = rc; applied["controller"] = AssetRefOf(rc); }
            }
            if (s.ContainsKey("avatar"))
            {
                Avatar av = null;
                if (s["avatar"] is string avs && avs.Length > 0) { var o = LoadAssetRef(avs, "avatar"); av = o as Avatar; Require(av != null, "typeMismatch", "The asset is not an Avatar. Use Assets/…fbx::AvatarName."); }
                if (c.avatar != av) { before["avatar"] = AssetRefOf(c.avatar); c.avatar = av; applied["avatar"] = AssetRefOf(av); }
            }
            if (s.ContainsKey("applyRootMotion")) { var v = B(s, "applyRootMotion"); Track("applyRootMotion", c.applyRootMotion, v, before, applied, () => c.applyRootMotion = v); }
            if (s.ContainsKey("updateMode")) { var v = EnumOf<AnimatorUpdateMode>(s["updateMode"], "updateMode"); Track("updateMode", c.updateMode, v, before, applied, () => c.updateMode = v, x => x.ToString()); }
            if (s.ContainsKey("cullingMode")) { var v = EnumOf<AnimatorCullingMode>(s["cullingMode"], "cullingMode"); Track("cullingMode", c.cullingMode, v, before, applied, () => c.cullingMode = v, x => x.ToString()); }
            if (s.ContainsKey("speed")) { var v = F(s, "speed"); Require(v >= -10 && v <= 10, "invalidValue", "speed must be between -10 and 10."); Track("speed", c.speed, v, before, applied, () => c.speed = v, Show, Near); }
            if (s.ContainsKey("enabled")) { var v = B(s, "enabled"); Track("enabled", c.enabled, v, before, applied, () => c.enabled = v); }
            return c;
#else
            throw new OpException("moduleMissing", "The Animation module is not enabled in this project.");
#endif
        }

        static Component ConfigureCanvas(GameObject go, D s, D before, D applied)
        {
#if JARVIS_UI
            NeedKeys(s, "canvas", "renderMode", "sortingOrder", "pixelPerfect", "enabled");
            var c = Need<Canvas>(go, "Canvas");
            Undo.RecordObject(c, "JARVIS configure canvas");
            if (s.ContainsKey("renderMode")) { var v = EnumOf<RenderMode>(s["renderMode"], "renderMode"); Track("renderMode", c.renderMode, v, before, applied, () => c.renderMode = v, x => x.ToString()); }
            if (s.ContainsKey("sortingOrder")) { var v = (int)Num(s, "sortingOrder"); Track("sortingOrder", c.sortingOrder, v, before, applied, () => c.sortingOrder = v); }
            if (s.ContainsKey("pixelPerfect")) { var v = B(s, "pixelPerfect"); Track("pixelPerfect", c.pixelPerfect, v, before, applied, () => c.pixelPerfect = v); }
            if (s.ContainsKey("enabled")) { var v = B(s, "enabled"); Track("enabled", c.enabled, v, before, applied, () => c.enabled = v); }
            return c;
#else
            throw new OpException("moduleMissing", "The UI module is not enabled in this project.");
#endif
        }

        static Component ConfigureRectTransform(GameObject go, D s, D before, D applied)
        {
            NeedKeys(s, "rectTransform", "anchorMin", "anchorMax", "pivot", "anchoredPosition", "sizeDelta", "offsetMin", "offsetMax");
            var c = go.transform as RectTransform;
            Require(c != null, "componentNotFound", "\"" + go.name + "\" has no RectTransform (it is not a UI object).");
            Undo.RecordObject(c, "JARVIS configure rect transform");
            Func<Vector2, Vector2, bool> sv = (x, y) => (x - y).sqrMagnitude < 1e-8f;
            Func<Vector2, object> shv = x => new List<object> { (double)x.x, (double)x.y };
            Func<string, Vector2> V2 = k => { var n = Nums(s[k], 2); return new Vector2(n[0], n[1]); };
            if (s.ContainsKey("anchorMin")) { var v = V2("anchorMin"); Track("anchorMin", c.anchorMin, v, before, applied, () => c.anchorMin = v, shv, sv); }
            if (s.ContainsKey("anchorMax")) { var v = V2("anchorMax"); Track("anchorMax", c.anchorMax, v, before, applied, () => c.anchorMax = v, shv, sv); }
            if (s.ContainsKey("pivot")) { var v = V2("pivot"); Track("pivot", c.pivot, v, before, applied, () => c.pivot = v, shv, sv); }
            if (s.ContainsKey("anchoredPosition")) { var v = V2("anchoredPosition"); Track("anchoredPosition", c.anchoredPosition, v, before, applied, () => c.anchoredPosition = v, shv, sv); }
            if (s.ContainsKey("sizeDelta")) { var v = V2("sizeDelta"); Track("sizeDelta", c.sizeDelta, v, before, applied, () => c.sizeDelta = v, shv, sv); }
            if (s.ContainsKey("offsetMin")) { var v = V2("offsetMin"); Track("offsetMin", c.offsetMin, v, before, applied, () => c.offsetMin = v, shv, sv); }
            if (s.ContainsKey("offsetMax")) { var v = V2("offsetMax"); Track("offsetMax", c.offsetMax, v, before, applied, () => c.offsetMax = v, shv, sv); }
            return c;
        }

        // ================================================================ prefabs

        static D InstantiatePrefab(D a)
        {
            string path = Str(a, "assetPath");
            Require(AssetPathOk(path) && new[] { ".prefab", ".fbx", ".obj", ".dae", ".blend", ".gltf", ".glb" }.Any(e => path.EndsWith(e, StringComparison.OrdinalIgnoreCase)), "invalidArguments", "assetPath must be a prefab or model inside Assets/.");
            var asset = AssetDatabase.LoadAssetAtPath<GameObject>(path);
            Require(asset != null, "assetNotFound", "No prefab or model exists at " + path + ".");
            var scene = SceneFor(Str(a, "scene"));
            GameObject parent = a.ContainsKey("parent") && a["parent"] is D pd ? Resolve(pd) : null;
            if (parent != null) Require(parent.scene == scene, "invalidArguments", "The parent is in a different scene.");
            string name = Str(a, "name");
            if (!string.IsNullOrEmpty(name) && Bool(a, "ifAbsent", true))
            {
                IEnumerable<Transform> sibs = parent != null ? Enumerable.Range(0, parent.transform.childCount).Select(i => parent.transform.GetChild(i)) : scene.GetRootGameObjects().Select(g => g.transform);
                var existing = sibs.Where(x => x.name == name && PrefabUtility.GetCorrespondingObjectFromSource(x.gameObject) == asset).ToList();
                if (existing.Count == 1) return Obj("created", false, "alreadyExists", true, "object", Identity(existing[0].gameObject));
            }
            var inst = (GameObject)PrefabUtility.InstantiatePrefab(asset, scene);
            Require(inst != null, "instantiateFailed", "Unity could not instantiate the prefab.");
            Undo.RegisterCreatedObjectUndo(inst, "JARVIS instantiate " + asset.name);
            if (parent != null) inst.transform.SetParent(parent.transform, false);
            if (!string.IsNullOrEmpty(name)) { Require(name.Length <= 80 && !name.Contains("/") && !name.Contains("#"), "invalidArguments", "A valid name (no / or #) is required."); inst.name = name; }
            if (a.TryGetValue("position", out var pos)) inst.transform.localPosition = ToVec3(pos);
            if (a.TryGetValue("rotation", out var rot)) inst.transform.localEulerAngles = ToVec3(rot);
            if (a.TryGetValue("scale", out var sc)) inst.transform.localScale = ToVec3(sc);
            NoteTouched(inst.transform);
            MarkDirty(scene);
            return Obj("created", true, "alreadyExists", false, "undoRecorded", true, "object", Identity(inst), "prefab", PrefabInfo(inst));
        }

        static IEnumerable<ObjectOverride> InstanceOverrides(GameObject root) => PrefabUtility.GetObjectOverrides(root, false);

        static D PrefabOverrides(D a)
        {
            var go = Resolve(Sub(a, "target"), true);
            var root = PrefabUtility.GetOutermostPrefabInstanceRoot(go);
            Require(root != null, "notAPrefabInstance", "\"" + go.name + "\" is not part of a prefab instance.");
            var list = new List<object>();
            int mine = 0, users = 0;
            foreach (var ov in InstanceOverrides(root))
            {
                bool jarvis = WasTouched(ov.instanceObject);
                if (jarvis) mine++; else users++;
                if (list.Count < 60) list.Add(Obj("object", ov.instanceObject == null ? null : ov.instanceObject.name, "type", ov.instanceObject == null ? null : ov.instanceObject.GetType().Name, "jarvis", jarvis));
            }
            return Obj("root", Identity(root), "prefab", PrefabInfo(root), "overrides", list, "jarvisOverrides", mine, "otherOverrides", users,
                       "addedComponents", PrefabUtility.GetAddedComponents(root).Count, "removedComponents", PrefabUtility.GetRemovedComponents(root).Count, "addedGameObjects", PrefabUtility.GetAddedGameObjects(root).Count);
        }

        static D RevertPrefabOverrides(D a)
        {
            var go = Resolve(Sub(a, "target"), true);
            var root = PrefabUtility.GetOutermostPrefabInstanceRoot(go);
            Require(root != null, "notAPrefabInstance", "\"" + go.name + "\" is not part of a prefab instance.");
            int reverted = 0, protectedCount = 0;
            foreach (var ov in InstanceOverrides(root).ToList())
            {
                if (!WasTouched(ov.instanceObject)) { protectedCount++; continue; }          // the user's own override is never reverted by JARVIS
                ov.Revert(InteractionMode.AutomatedAction); reverted++;
            }
            if (reverted > 0) MarkDirty(root.scene);
            return Obj("reverted", reverted, "protectedUserOverrides", protectedCount, "root", Identity(root));
        }

        static D ApplyPrefabOverrides(D a)
        {
            var go = Resolve(Sub(a, "target"), true);
            var root = PrefabUtility.GetOutermostPrefabInstanceRoot(go);
            Require(root != null, "notAPrefabInstance", "\"" + go.name + "\" is not part of a prefab instance.");
            int applied = 0, protectedCount = 0;
            foreach (var ov in InstanceOverrides(root).ToList())
            {
                if (!WasTouched(ov.instanceObject)) { protectedCount++; continue; }          // only what JARVIS changed is written into the shared prefab
                ov.Apply(InteractionMode.AutomatedAction); applied++;
            }
            if (applied > 0) { AssetDatabase.SaveAssets(); MarkDirty(root.scene); }
            return Obj("applied", applied, "protectedUserOverrides", protectedCount, "root", Identity(root), "prefabAsset", AssetDatabase.GetAssetPath(PrefabUtility.GetCorrespondingObjectFromSource(root)));
        }

        static D CreatePrefabVariant(D a)
        {
            string src = Str(a, "sourceAssetPath"), path = Str(a, "assetPath");
            Require(AssetPathOk(src, ".prefab") && AssetPathOk(path, ".prefab"), "invalidArguments", "sourceAssetPath and assetPath must be .prefab files inside Assets/.");
            Require(!File.Exists(Abs(path)), "assetExists", "A prefab already exists at that path; the bridge never overwrites assets.");
            var source = AssetDatabase.LoadAssetAtPath<GameObject>(src);
            Require(source != null, "assetNotFound", "No prefab exists at " + src + ".");
            Directory.CreateDirectory(Path.GetDirectoryName(Abs(path)));
            var preview = EditorSceneManager.NewPreviewScene();
            try
            {
                var inst = (GameObject)PrefabUtility.InstantiatePrefab(source, preview);
                var variant = PrefabUtility.SaveAsPrefabAsset(inst, path, out bool ok);
                Require(ok && variant != null, "prefabFailed", "Unity could not create the variant.");
                var type = PrefabUtility.GetPrefabAssetType(variant).ToString();
                Require(type == "Variant", "prefabFailed", "The saved prefab is not a variant (it is " + type + ").");
                return Obj("created", true, "assetPath", path, "source", src, "assetType", type);
            }
            finally { EditorSceneManager.ClosePreviewScene(preview); }
        }

        static D UnpackPrefab(D a)
        {
            var go = Resolve(Sub(a, "target"));
            var root = PrefabUtility.GetOutermostPrefabInstanceRoot(go);
            Require(root != null, "notAPrefabInstance", "\"" + go.name + "\" is not part of a prefab instance.");
            var mode = Str(a, "mode", "outermostRoot") == "completely" ? PrefabUnpackMode.Completely : PrefabUnpackMode.OutermostRoot;
            PrefabUtility.UnpackPrefabInstance(root, mode, InteractionMode.AutomatedAction);
            MarkDirty(root.scene);
            return Obj("unpacked", true, "mode", mode.ToString(), "root", Identity(root));
        }

        // ================================================================ environment & lighting

        static D EnvSnapshot() => Obj("ambientMode", RenderSettings.ambientMode.ToString(), "ambientLight", ColorList(RenderSettings.ambientLight), "ambientIntensity", (double)RenderSettings.ambientIntensity,
            "ambientSkyColor", ColorList(RenderSettings.ambientSkyColor), "ambientEquatorColor", ColorList(RenderSettings.ambientEquatorColor), "ambientGroundColor", ColorList(RenderSettings.ambientGroundColor),
            "fog", RenderSettings.fog, "fogColor", ColorList(RenderSettings.fogColor), "fogMode", RenderSettings.fogMode.ToString(), "fogDensity", (double)RenderSettings.fogDensity,
            "fogStartDistance", (double)RenderSettings.fogStartDistance, "fogEndDistance", (double)RenderSettings.fogEndDistance, "reflectionIntensity", (double)RenderSettings.reflectionIntensity,
            "skybox", AssetRefOf(RenderSettings.skybox), "sun", RenderSettings.sun == null ? null : HierarchyPath(RenderSettings.sun.transform, true));

        static D InspectLighting(D a)
        {
            var scene = SceneFor(Str(a, "scene"));
            var lights = new List<object>();
            int probes = 0, reflection = 0;
            foreach (var go in AllObjects(scene))
            {
                var l = go.GetComponent<Light>();
                if (l != null && lights.Count < 40)
                    lights.Add(Obj("path", HierarchyPath(go.transform, true), "type", l.type.ToString(), "enabled", l.enabled && go.activeInHierarchy, "intensity", (double)l.intensity, "range", (double)l.range, "spotAngle", (double)l.spotAngle,
                                   "color", ColorList(l.color), "shadows", l.shadows.ToString(), "eulerAngles", Vec(go.transform.eulerAngles), "position", Vec(go.transform.position), "mode", l.lightmapBakeType.ToString()));
                if (go.GetComponent<LightProbeGroup>() != null) probes++;
                if (go.GetComponent<ReflectionProbe>() != null) reflection++;
            }
            string rp = "Built-in", asset = null;
            try { var p = UnityEngine.Rendering.GraphicsSettings.currentRenderPipeline; if (p != null) { rp = p.GetType().Name; asset = AssetDatabase.GetAssetPath(p); } } catch (Exception) { }
            return Obj("scene", scene.path, "lights", lights, "lightProbeGroups", probes, "reflectionProbes", reflection, "environment", EnvSnapshot(), "renderPipeline", rp, "renderPipelineAsset", asset, "colorSpace", PlayerSettings.colorSpace.ToString());
        }

        static D SetEnvironment(D a)
        {
            string prop = Str(a, "property");
            Require(a.ContainsKey("value"), "invalidArguments", "value is required.");
            var value = a["value"];
            var before = EnvSnapshot();
            object old = before.TryGetValue(prop, out var o) ? o : null;
            switch (prop)
            {
                case "ambientMode": RenderSettings.ambientMode = EnumOf<UnityEngine.Rendering.AmbientMode>(value, "ambientMode"); break;
                case "ambientLight": RenderSettings.ambientLight = ColorOf(value, prop); break;
                case "ambientSkyColor": RenderSettings.ambientSkyColor = ColorOf(value, prop); break;
                case "ambientEquatorColor": RenderSettings.ambientEquatorColor = ColorOf(value, prop); break;
                case "ambientGroundColor": RenderSettings.ambientGroundColor = ColorOf(value, prop); break;
                case "ambientIntensity": { Require(value is double d1 && d1 >= 0 && d1 <= 8, "invalidValue", "ambientIntensity must be between 0 and 8."); RenderSettings.ambientIntensity = (float)(double)value; break; }
                case "fog": Require(value is bool, "invalidValue", "fog must be true or false."); RenderSettings.fog = (bool)value; break;
                case "fogColor": RenderSettings.fogColor = ColorOf(value, prop); break;
                case "fogMode": RenderSettings.fogMode = EnumOf<FogMode>(value, "fogMode"); break;
                case "fogDensity": { Require(value is double d2 && d2 >= 0 && d2 <= 1, "invalidValue", "fogDensity must be between 0 and 1."); RenderSettings.fogDensity = (float)(double)value; break; }
                case "fogStartDistance": { Require(value is double d3 && d3 >= 0, "invalidValue", "fogStartDistance must not be negative."); RenderSettings.fogStartDistance = (float)(double)value; break; }
                case "fogEndDistance": { Require(value is double d4 && d4 >= 0, "invalidValue", "fogEndDistance must not be negative."); RenderSettings.fogEndDistance = (float)(double)value; break; }
                case "reflectionIntensity": { Require(value is double d5 && d5 >= 0 && d5 <= 1, "invalidValue", "reflectionIntensity must be between 0 and 1."); RenderSettings.reflectionIntensity = (float)(double)value; break; }
                default: throw new OpException("unknownSetting", "\"" + prop + "\" is not a supported environment setting. Supported: ambientMode, ambientLight, ambientSkyColor, ambientEquatorColor, ambientGroundColor, ambientIntensity, fog, fogColor, fogMode, fogDensity, fogStartDistance, fogEndDistance, reflectionIntensity.");
            }
            var after = EnvSnapshot();
            bool changed = Json.Serialize(old) != Json.Serialize(after[prop]);
            if (changed) MarkDirty(SceneManager.GetActiveScene());
            return Obj("changed", changed, "alreadyApplied", !changed, "property", prop, "before", old, "value", after[prop], "scene", SceneManager.GetActiveScene().path);
        }
    }
}
