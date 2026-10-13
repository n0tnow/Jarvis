#if JARVIS_HAS_INPUTSYSTEM
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.InputSystem;

namespace Jarvis.Bridge
{
    using D = Dictionary<string, object>;

    /// <summary>
    /// V0.13.1 — Input System operations (only compiled when com.unity.inputsystem is installed). An .inputactions asset is read and written ONLY through Unity's own
    /// InputActionAsset API (FromJson / ToJson, AddActionMap, AddAction, AddBinding, ChangeBinding) — never by text-editing the file — and every edit is verified by loading the
    /// saved file again. Bindings JARVIS creates are remembered (Library/JarvisBridge/input-owned.json); only those can be changed or removed. An exact duplicate is not added, and a
    /// binding that would share a control with another action of the same map (or uses a wildcard such as anyKey) is REFUSED with the facts, never guessed.
    /// </summary>
    [InitializeOnLoad]
    static class JarvisInputOps
    {
        static string OwnedFile => Path.Combine(JarvisBridge.Root, "input-owned.json");

        static JarvisInputOps()
        {
            JarvisBridge.Register("inspectInput", Inspect, false);
            JarvisBridge.Register("createInputAsset", CreateAsset, true);
            JarvisBridge.Register("createInputMap", CreateMap, true);
            JarvisBridge.Register("createInputAction", CreateAction, true);
            JarvisBridge.Register("addInputBinding", AddBinding, true);
            JarvisBridge.Register("changeInputBinding", ChangeBinding, true);
            JarvisBridge.Register("removeInputBinding", RemoveBinding, true);
        }

        // ------------------------------------------------------------------ helpers

        static void Require(bool ok, string code, string msg, object extra = null) { if (!ok) throw new OpException(code, msg, extra); }
        static string Str(D a, string k) => a.TryGetValue(k, out var v) && v is string s ? s : null;
        static D Obj(params object[] kv) { var d = new D(); for (int i = 0; i + 1 < kv.Length; i += 2) d[(string)kv[i]] = kv[i + 1]; return d; }

        static string AssetPath(D a)
        {
            var p = Str(a, "assetPath");
            Require(!string.IsNullOrEmpty(p) && p.StartsWith("Assets/", StringComparison.Ordinal) && p.EndsWith(".inputactions", StringComparison.Ordinal) && !p.Contains("..") && !p.Contains("\\") && p.Length <= 240,
                    "invalidArguments", "assetPath must be an .inputactions asset inside Assets/.");
            return p;
        }
        static string Abs(string assetPath) => Path.Combine(JarvisBridge.ProjectPath, assetPath);

        static InputActionAsset Load(string assetPath)
        {
            Require(File.Exists(Abs(assetPath)), "assetNotFound", "No input actions asset exists at " + assetPath + ".");
            try { return InputActionAsset.FromJson(File.ReadAllText(Abs(assetPath))); }
            catch (Exception e) { throw new OpException("assetUnreadable", "Unity could not read " + assetPath + " as input actions: " + JarvisBridge.Trim(e.Message, 160)); }
        }

        static void Save(InputActionAsset asset, string assetPath)
        {
            asset.name = Path.GetFileNameWithoutExtension(assetPath);
            File.WriteAllText(Abs(assetPath), asset.ToJson());
            AssetDatabase.ImportAsset(assetPath, ImportAssetOptions.ForceUpdate);
        }

        static HashSet<string> Owned()
        {
            try { if (File.Exists(OwnedFile) && Json.Parse(File.ReadAllText(OwnedFile)) is D d && d.TryGetValue("ids", out var l) && l is List<object> ids) return new HashSet<string>(ids.OfType<string>()); }
            catch (Exception) { }
            return new HashSet<string>();
        }
        static void SaveOwned(HashSet<string> ids) { JarvisBridge.AtomicWrite(OwnedFile, Json.Serialize(Obj("ids", ids.OrderBy(x => x, StringComparer.Ordinal).Cast<object>().ToList()))); }

        static InputActionMap Map(InputActionAsset asset, D a, bool must = true)
        {
            var name = Str(a, "map");
            var m = asset.actionMaps.FirstOrDefault(x => x.name == name);
            if (must) Require(m != null, "mapNotFound", "There is no action map \"" + name + "\" in this asset. Maps: " + string.Join(", ", asset.actionMaps.Select(x => x.name)) + ".");
            return m;
        }
        static InputAction Action(InputActionMap map, D a, bool must = true)
        {
            var name = Str(a, "action");
            var act = map.actions.FirstOrDefault(x => x.name == name);
            if (must) Require(act != null, "actionNotFound", "There is no action \"" + name + "\" in map \"" + map.name + "\". Actions: " + string.Join(", ", map.actions.Select(x => x.name)) + ".");
            return act;
        }

        static D BindingInfo(InputBinding b, HashSet<string> owned) => Obj("id", b.id.ToString(), "path", b.path, "name", b.name, "groups", b.groups, "interactions", b.interactions, "processors", b.processors,
                                                                          "isComposite", b.isComposite, "isPartOfComposite", b.isPartOfComposite, "ownedByJarvis", owned.Contains(b.id.ToString()));

        static D ActionInfo(InputAction a, HashSet<string> owned) => Obj("name", a.name, "id", a.id.ToString(), "type", a.type.ToString(), "expectedControlType", a.expectedControlType ?? "", "interactions", a.interactions, "processors", a.processors,
                                                                       "bindings", a.bindings.Select(b => (object)BindingInfo(b, owned)).ToList());

        static D AssetInfo(InputActionAsset asset, string path, HashSet<string> owned) => Obj("path", path, "name", asset.name,
            "maps", asset.actionMaps.Select(m => (object)Obj("name", m.name, "id", m.id.ToString(), "actions", m.actions.Select(a => (object)ActionInfo(a, owned)).ToList())).ToList(),
            "controlSchemes", asset.controlSchemes.Select(s => (object)Obj("name", s.name, "bindingGroup", s.bindingGroup, "devices", s.deviceRequirements.Select(r => (object)Obj("path", r.controlPath, "optional", r.isOptional)).ToList())).ToList());

        // ------------------------------------------------------------------ reads

        static D Inspect(D a)
        {
            var info = UnityEditor.PackageManager.PackageInfo.FindForAssembly(typeof(InputAction).Assembly);
            var assets = new List<object>();
            var root = Path.Combine(JarvisBridge.ProjectPath, "Assets");
            if (Directory.Exists(root))
                foreach (var f in Directory.GetFiles(root, "*.inputactions", SearchOption.AllDirectories).OrderBy(x => x, StringComparer.Ordinal).Take(50))
                    assets.Add("Assets/" + f.Substring(root.Length + 1).Replace('\\', '/'));
            var d = Obj("package", Obj("installed", true, "version", info != null ? info.version : "installed"), "assets", assets);
            var path = Str(a, "assetPath");
            if (!string.IsNullOrEmpty(path))
            {
                var p = AssetPath(a);
                var asset = Load(p);
                try { d["asset"] = AssetInfo(asset, p, Owned()); } finally { UnityEngine.Object.DestroyImmediate(asset); }
            }
            return d;
        }

        // ------------------------------------------------------------------ writes

        static D CreateAsset(D a)
        {
            var p = AssetPath(a);
            if (File.Exists(Abs(p))) return Obj("created", false, "alreadyExists", true, "verified", true);
            Directory.CreateDirectory(Path.GetDirectoryName(Abs(p)));          // the path was validated to stay inside Assets/ (no "..", no backslash)
            File.WriteAllText(Abs(p), "{\n    \"name\": \"" + Path.GetFileNameWithoutExtension(p) + "\",\n    \"maps\": [],\n    \"controlSchemes\": []\n}\n");
            AssetDatabase.ImportAsset(p, ImportAssetOptions.ForceUpdate);
            var back = Load(p);
            try { return Obj("created", true, "alreadyExists", false, "verified", back.actionMaps.Count == 0); } finally { UnityEngine.Object.DestroyImmediate(back); }
        }

        static D CreateMap(D a)
        {
            var p = AssetPath(a); var name = Str(a, "name");
            var asset = Load(p);
            try
            {
                if (asset.actionMaps.Any(m => m.name == name)) return Obj("created", false, "alreadyExists", true, "verified", true);
                asset.AddActionMap(name);
                Save(asset, p);
            }
            finally { UnityEngine.Object.DestroyImmediate(asset); }
            var back = Load(p);
            try { return Obj("created", true, "alreadyExists", false, "verified", back.actionMaps.Any(m => m.name == name)); } finally { UnityEngine.Object.DestroyImmediate(back); }
        }

        static D CreateAction(D a)
        {
            var p = AssetPath(a); var name = Str(a, "name");
            var type = Str(a, "actionType") ?? "Button";
            Require(Enum.TryParse<InputActionType>(type, out var t), "invalidArguments", "actionType must be Button, Value or PassThrough.");
            var expected = Str(a, "expectedControlType");
            var asset = Load(p);
            try
            {
                var map = Map(asset, a);
                if (map.actions.Any(x => x.name == name)) return Obj("created", false, "alreadyExists", true, "verified", true);
                var action = map.AddAction(name, t);
                if (!string.IsNullOrEmpty(expected)) action.expectedControlType = expected;
                Save(asset, p);
            }
            finally { UnityEngine.Object.DestroyImmediate(asset); }
            var back = Load(p);
            try
            {
                var act = back.actionMaps.FirstOrDefault(m => m.name == Str(a, "map"))?.actions.FirstOrDefault(x => x.name == name);
                bool ok = act != null && act.type == t && (string.IsNullOrEmpty(expected) || act.expectedControlType == expected);
                return Obj("created", true, "alreadyExists", false, "verified", ok);
            }
            finally { UnityEngine.Object.DestroyImmediate(back); }
        }

        /// <summary>Other actions of the same map that already use this control — or a wildcard overlap that cannot be judged. Never decided here: reported.</summary>
        static List<object> Conflicts(InputActionMap map, InputAction target, string path, string ignoreId)
        {
            var found = new List<object>();
            bool wildcard = path.EndsWith("/anyKey", StringComparison.OrdinalIgnoreCase);
            foreach (var other in map.actions)
                foreach (var b in other.bindings)
                {
                    if (b.id.ToString() == ignoreId || string.IsNullOrEmpty(b.path)) continue;
                    bool sameControl = string.Equals(b.path, path, StringComparison.OrdinalIgnoreCase);
                    bool otherWildcard = b.path.EndsWith("/anyKey", StringComparison.OrdinalIgnoreCase) && path.StartsWith("<Keyboard>", StringComparison.OrdinalIgnoreCase);
                    if (other == target && sameControl) continue;       // an exact duplicate on the SAME action is reported separately
                    if (sameControl && other != target) found.Add(Obj("kind", "likely", "action", other.name, "path", b.path, "bindingId", b.id.ToString()));
                    else if (wildcard || otherWildcard) found.Add(Obj("kind", "unknown", "action", other.name, "path", b.path, "bindingId", b.id.ToString(), "why", "a wildcard control (anyKey) overlaps other keys"));
                }
            return found;
        }

        static D AddBinding(D a)
        {
            var p = AssetPath(a); var path = Str(a, "path"); var groups = Str(a, "groups");
            Require(!string.IsNullOrEmpty(path), "invalidArguments", "path is required.");
            string newId; D result;
            var asset = Load(p);
            try
            {
                var map = Map(asset, a); var action = Action(map, a);
                var dup = action.bindings.FirstOrDefault(b => string.Equals(b.path, path, StringComparison.OrdinalIgnoreCase) && (string.IsNullOrEmpty(groups) || b.groups == groups));
                if (!string.IsNullOrEmpty(dup.path)) return Obj("added", false, "duplicate", true, "bindingId", dup.id.ToString(), "verified", true, "message", "The action already has exactly this binding; nothing was added.");
                var conflicts = Conflicts(map, action, path, null);
                if (conflicts.Count > 0) throw new OpException("inputConflict", "Binding " + path + " to " + map.name + "/" + action.name + " would share a control with another action of this map (" +
                    string.Join("; ", conflicts.Cast<D>().Select(c => c["action"] + " " + c["path"] + " [" + c["kind"] + "]")) + "). JARVIS does not guess: decide which action should own it.", conflicts);
                action.AddBinding(path, null, null, string.IsNullOrEmpty(groups) ? null : groups);
                newId = action.bindings[action.bindings.Count - 1].id.ToString();
                Save(asset, p);
            }
            finally { UnityEngine.Object.DestroyImmediate(asset); }
            var owned = Owned(); owned.Add(newId); SaveOwned(owned);
            var back = Load(p);
            try
            {
                var act = back.actionMaps.FirstOrDefault(m => m.name == Str(a, "map"))?.actions.FirstOrDefault(x => x.name == Str(a, "action"));
                var b = act?.bindings.FirstOrDefault(x => x.id.ToString() == newId);
                result = Obj("added", true, "duplicate", false, "bindingId", newId, "verified", b.HasValue && b.Value.path == path);
            }
            finally { UnityEngine.Object.DestroyImmediate(back); }
            return result;
        }

        static int IndexOf(InputAction action, string id)
        {
            for (int i = 0; i < action.bindings.Count; i++) if (action.bindings[i].id.ToString() == id) return i;
            return -1;
        }

        static void RequireOwned(string id)
        {
            Require(Owned().Contains(id), "userBinding", "That binding was not created by JARVIS (or JARVIS no longer remembers it), so JARVIS will not change or remove it. Edit it yourself in the Input Actions editor.");
        }

        static D ChangeBinding(D a)
        {
            var p = AssetPath(a); var path = Str(a, "path"); var id = Str(a, "bindingId");
            Require(!string.IsNullOrEmpty(path) && !string.IsNullOrEmpty(id), "invalidArguments", "path and bindingId are required.");
            var asset = Load(p);
            try
            {
                var map = Map(asset, a); var action = Action(map, a);
                int idx = IndexOf(action, id);
                Require(idx >= 0, "bindingNotFound", "Action " + action.name + " has no binding with id " + id + ".");
                RequireOwned(id);
                if (string.Equals(action.bindings[idx].path, path, StringComparison.OrdinalIgnoreCase)) return Obj("changed", false, "verified", true, "message", "The binding already has this path.");
                var conflicts = Conflicts(map, action, path, id);
                if (conflicts.Count > 0) throw new OpException("inputConflict", "Changing the binding to " + path + " would share a control with another action of this map. JARVIS does not guess.", conflicts);
                action.ChangeBinding(idx).WithPath(path);
                Save(asset, p);
            }
            finally { UnityEngine.Object.DestroyImmediate(asset); }
            var back = Load(p);
            try
            {
                var act = back.actionMaps.FirstOrDefault(m => m.name == Str(a, "map"))?.actions.FirstOrDefault(x => x.name == Str(a, "action"));
                var b = act?.bindings.FirstOrDefault(x => x.id.ToString() == id);
                return Obj("changed", true, "verified", b.HasValue && b.Value.path == path);
            }
            finally { UnityEngine.Object.DestroyImmediate(back); }
        }

        static D RemoveBinding(D a)
        {
            var p = AssetPath(a); var id = Str(a, "bindingId");
            Require(!string.IsNullOrEmpty(id), "invalidArguments", "bindingId is required.");
            var asset = Load(p);
            try
            {
                var map = Map(asset, a); var action = Action(map, a);
                int idx = IndexOf(action, id);
                Require(idx >= 0, "bindingNotFound", "Action " + action.name + " has no binding with id " + id + ".");
                RequireOwned(id);
                action.ChangeBinding(idx).Erase();
                Save(asset, p);
            }
            finally { UnityEngine.Object.DestroyImmediate(asset); }
            var owned = Owned(); owned.Remove(id); SaveOwned(owned);
            var back = Load(p);
            try
            {
                var act = back.actionMaps.FirstOrDefault(m => m.name == Str(a, "map"))?.actions.FirstOrDefault(x => x.name == Str(a, "action"));
                return Obj("removed", true, "verified", act != null && IndexOf(act, id) < 0);
            }
            finally { UnityEngine.Object.DestroyImmediate(back); }
        }
    }
}
#endif
