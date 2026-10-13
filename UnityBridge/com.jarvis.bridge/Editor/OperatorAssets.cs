using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;
#if JARVIS_ANIMATION
using UnityEditor.Animations;
#endif

namespace Jarvis.Bridge
{
    using D = Dictionary<string, object>;

    /// <summary>
    /// V0.13 — asset-level operations (materials, animator controllers, importers, audio), the runtime snapshot, and the camera capture. Everything is typed and bounded; assets are
    /// only ever CREATED at new paths or modified through their typed API (never overwritten, never deleted); anything that needs a module the project does not have answers
    /// "moduleMissing" instead of failing to compile the bridge.
    /// </summary>
    internal static partial class Ops
    {
        // ================================================================ inspectAsset

        static D InspectAsset(D a)
        {
            string path = Str(a, "path");
            Require(AssetPathOk(path), "invalidArguments", "path must be an asset path inside Assets/.");
            Require(File.Exists(Abs(path)), "assetNotFound", "No asset exists at " + path + ".");
            var main = AssetDatabase.LoadMainAssetAtPath(path);
            Require(main != null, "assetNotFound", "Unity could not load " + path + " (is it imported yet?).");
            var d = Obj("path", path, "type", main.GetType().Name, "name", main.name, "guid", AssetDatabase.AssetPathToGUID(path));
            var importer = AssetImporter.GetAtPath(path);
            if (importer != null) d["importer"] = importer.GetType().Name;

            if (main is Material mat) { foreach (var kv in MaterialInfo(mat)) d[kv.Key] = kv.Value; return d; }
            if (main is Shader sh) { d["properties"] = ShaderProps(sh); return d; }
            if (main is Texture tex)
            {
                d["width"] = tex.width; d["height"] = tex.height;
                if (importer is TextureImporter ti) { d["textureType"] = ti.textureType.ToString(); d["sRGB"] = ti.sRGBTexture; d["maxSize"] = ti.maxTextureSize; d["mipmaps"] = ti.mipmapEnabled; }
                return d;
            }
#if JARVIS_AUDIO
            if (main is AudioClip clip)
            {
                d["length"] = (double)clip.length; d["frequency"] = clip.frequency; d["channels"] = clip.channels; d["samples"] = clip.samples; d["loadType"] = clip.loadType.ToString();
                d["loadState"] = clip.loadState.ToString(); d["ambisonic"] = clip.ambisonic;
                if (importer is AudioImporter ai)
                {
                    var ds = ai.defaultSampleSettings;
                    d["forceToMono"] = ai.forceToMono; d["loadInBackground"] = ai.loadInBackground; d["compression"] = ds.compressionFormat.ToString(); d["quality"] = (double)ds.quality; d["importLoadType"] = ds.loadType.ToString();
                }
                return d;
            }
            if (main is UnityEngine.Audio.AudioMixer mixer)
            {
                var exposed = new List<object>();
                var so = new SerializedObject(mixer);
                var arr = so.FindProperty("m_ExposedParameters");
                if (arr != null && arr.isArray) for (int i = 0; i < arr.arraySize && i < 40; i++) { var n = arr.GetArrayElementAtIndex(i).FindPropertyRelative("name"); if (n != null) exposed.Add(n.stringValue); }
                d["exposedParameters"] = exposed;
                d["groups"] = mixer.FindMatchingGroups("").Select(g => (object)g.name).Take(40).ToList();
                return d;
            }
#endif
#if JARVIS_ANIMATION
            if (main is AnimationClip ac)
            {
                foreach (var kv in ClipInfo(ac)) d[kv.Key] = kv.Value;
                return d;
            }
            if (main is AnimatorController ctl) { foreach (var kv in ControllerInfo(ctl)) d[kv.Key] = kv.Value; return d; }
#endif
            if (main is GameObject go)
            {
                if (importer is ModelImporter mi) { foreach (var kv in ModelInfo(path, mi)) d[kv.Key] = kv.Value; return d; }
                d["assetType"] = PrefabUtility.GetPrefabAssetType(go).ToString();
                var baseAsset = PrefabUtility.GetCorrespondingObjectFromSource(go);
                if (baseAsset != null) d["variantOf"] = AssetDatabase.GetAssetPath(baseAsset);
                d["components"] = go.GetComponents<Component>().Where(c => c != null).Select(c => (object)c.GetType().Name).Take(20).ToList();
                d["children"] = go.transform.childCount;
                d["missingScripts"] = GameObjectUtility.GetMonoBehavioursWithMissingScriptCount(go);
                return d;
            }
            return d;
        }

        static List<object> ShaderProps(Shader sh)
        {
            var l = new List<object>();
            int n = Math.Min(sh.GetPropertyCount(), 80);
            for (int i = 0; i < n; i++)
                if ((sh.GetPropertyFlags(i) & UnityEngine.Rendering.ShaderPropertyFlags.HideInInspector) == 0)
                    l.Add(Obj("name", sh.GetPropertyName(i), "type", sh.GetPropertyType(i).ToString(), "description", sh.GetPropertyDescription(i)));
            return l;
        }

        static D MaterialInfo(Material m)
        {
            var props = new List<object>();
            var sh = m.shader;
            int n = Math.Min(sh.GetPropertyCount(), 80);
            for (int i = 0; i < n; i++)
            {
                string name = sh.GetPropertyName(i);
                var type = sh.GetPropertyType(i);
                object value = null;
                switch (type)
                {
                    case UnityEngine.Rendering.ShaderPropertyType.Float: case UnityEngine.Rendering.ShaderPropertyType.Range: value = (double)m.GetFloat(name); break;
                    case UnityEngine.Rendering.ShaderPropertyType.Int: value = (double)m.GetInteger(name); break;
                    case UnityEngine.Rendering.ShaderPropertyType.Color: value = ColorList(m.GetColor(name)); break;
                    case UnityEngine.Rendering.ShaderPropertyType.Vector: { var v = m.GetVector(name); value = new List<object> { (double)v.x, (double)v.y, (double)v.z, (double)v.w }; break; }
                    case UnityEngine.Rendering.ShaderPropertyType.Texture: value = AssetRefOf(m.GetTexture(name)); break;
                }
                if ((sh.GetPropertyFlags(i) & UnityEngine.Rendering.ShaderPropertyFlags.HideInInspector) != 0) continue;
                props.Add(Obj("name", name, "type", type.ToString(), "value", value));
            }
            bool srp = false;
            try { srp = UnityEngine.Rendering.GraphicsSettings.currentRenderPipeline != null; } catch (Exception) { }
            return Obj("shader", sh.name, "renderQueue", m.renderQueue, "keywords", m.enabledKeywords.Select(k => (object)k.name).Take(30).ToList(), "properties", props,
                       "pipelineMismatch", srp && sh.name.StartsWith("Standard"), "shaderSupported", sh.isSupported);
        }

#if JARVIS_ANIMATION
        static D ClipInfo(AnimationClip c) => Obj("length", (double)c.length, "frameRate", (double)c.frameRate, "looping", c.isLooping, "legacy", c.legacy, "humanMotion", c.isHumanMotion, "hasMotionCurves", c.hasMotionCurves,
            "hasRootCurves", c.hasRootCurves, "empty", c.empty, "events", c.events.Length, "curves", AnimationUtility.GetCurveBindings(c).Length + AnimationUtility.GetObjectReferenceCurveBindings(c).Length, "wrapMode", c.wrapMode.ToString());

        static D ControllerInfo(AnimatorController c)
        {
            var ps = c.parameters.Select(p => (object)Obj("name", p.name, "type", p.type.ToString(), "default", p.type == AnimatorControllerParameterType.Float ? (double)p.defaultFloat : p.type == AnimatorControllerParameterType.Int ? (double)p.defaultInt : (object)p.defaultBool)).ToList();
            var layers = new List<object>();
            foreach (var l in c.layers)
            {
                var sm = l.stateMachine;
                var states = new List<object>();
                foreach (var cs in sm.states.Take(60))
                {
                    var st = cs.state;
                    var trans = st.transitions.Select(t => (object)TransitionInfo(st.name, t)).ToList();
                    states.Add(Obj("name", st.name, "motion", AssetRefOf(st.motion) ?? (st.motion is BlendTree ? "BlendTree:" + st.motion.name : null), "speed", (double)st.speed, "isDefault", sm.defaultState == st, "transitions", trans));
                }
                layers.Add(Obj("name", l.name, "defaultState", sm.defaultState == null ? null : sm.defaultState.name, "states", states, "anyStateTransitions", sm.anyStateTransitions.Select(t => (object)TransitionInfo("Any", t)).ToList()));
            }
            return Obj("parameters", ps, "layers", layers);
        }

        static D TransitionInfo(string from, AnimatorStateTransition t) => Obj("from", from, "to", t.destinationState == null ? null : t.destinationState.name, "hasExitTime", t.hasExitTime, "exitTime", (double)t.exitTime, "duration", (double)t.duration,
            "conditions", t.conditions.Select(c => (object)Obj("parameter", c.parameter, "mode", c.mode.ToString(), "threshold", (double)c.threshold)).ToList());
#endif

        static D ModelInfo(string path, ModelImporter mi)
        {
            var d = new D();
            d["animationType"] = mi.animationType.ToString(); d["importAnimation"] = mi.importAnimation; d["optimizeGameObjects"] = mi.optimizeGameObjects; d["isReadable"] = mi.isReadable;
#if JARVIS_ANIMATION
            var all = AssetDatabase.LoadAllAssetsAtPath(path);
            var clips = all.OfType<AnimationClip>().Where(c => !c.name.StartsWith("__preview__")).ToList();
            var loops = (mi.clipAnimations != null && mi.clipAnimations.Length > 0 ? mi.clipAnimations : mi.defaultClipAnimations).ToDictionary(x => x.name, x => x.loopTime, StringComparer.Ordinal);
            d["clips"] = clips.Select(c => (object)Obj("name", c.name, "length", (double)c.length, "frameRate", (double)c.frameRate, "loop", loops.TryGetValue(c.name, out var lp) && lp, "humanMotion", c.isHumanMotion)).Take(40).ToList();
            var av = all.OfType<Avatar>().FirstOrDefault();
            d["avatar"] = av == null ? null : Obj("name", av.name, "valid", av.isValid, "human", av.isHuman);
#endif
            d["meshCount"] = AssetDatabase.LoadAllAssetsAtPath(path).OfType<Mesh>().Count();
            return d;
        }

        // ================================================================ materials

        static D CreateMaterial(D a)
        {
            string path = Str(a, "assetPath");
            Require(AssetPathOk(path, ".mat"), "invalidArguments", "assetPath must be a new .mat inside Assets/.");
            Require(!File.Exists(Abs(path)), "assetExists", "A material already exists at that path; the bridge never overwrites assets.");
            Material mat;
            if (Has(a, "copyFrom"))
            {
                var src = LoadAssetRef(S(a, "copyFrom"), "copyFrom") as Material;
                Require(src != null, "typeMismatch", "copyFrom is not a Material.");
                mat = new Material(src);
            }
            else
            {
                string shaderName = Str(a, "shader");
                Require(!string.IsNullOrEmpty(shaderName), "invalidArguments", "shader (or copyFrom) is required.");
                var shader = Shader.Find(shaderName);
                if (shader == null)
                {
                    var known = ShaderUtil.GetAllShaderInfo().Select(i => i.name).Where(n => !n.StartsWith("Hidden/") && (n.StartsWith("Universal") || n.StartsWith("Standard") || n.StartsWith("Unlit") || n.StartsWith("Sprites") || n.StartsWith("HDRP") || n.StartsWith("Lit") || n.StartsWith("Particles"))).Take(20).ToList();
                    throw new OpException("shaderNotFound", "No shader named \"" + shaderName + "\" exists in this project.", known.Cast<object>().ToList());
                }
                mat = new Material(shader);
            }
            Directory.CreateDirectory(Path.GetDirectoryName(Abs(path)));
            AssetDatabase.CreateAsset(mat, path);
            AssetDatabase.SaveAssets();
            var created = AssetDatabase.LoadAssetAtPath<Material>(path);
            Require(created != null, "createFailed", "Unity could not create the material.");
            return Obj("created", true, "assetPath", path, "shader", created.shader.name, "pipelineMismatch", (bool)MaterialInfo(created)["pipelineMismatch"]);
        }

        static D SetMaterialProperty(D a)
        {
            string path = Str(a, "assetPath");
            Require(AssetPathOk(path, ".mat"), "invalidArguments", "assetPath must be a .mat inside Assets/.");
            var mat = AssetDatabase.LoadAssetAtPath<Material>(path);
            Require(mat != null, "assetNotFound", "No material exists at " + path + ".");
            string name = Str(a, "property");
            Require(a.ContainsKey("value"), "invalidArguments", "value is required.");
            var sh = mat.shader;
            int idx = sh.FindPropertyIndex(name);
            if (idx < 0) throw new OpException("propertyNotFound", "The shader \"" + sh.name + "\" has no property \"" + name + "\". Its properties are: " + string.Join(", ", Enumerable.Range(0, Math.Min(sh.GetPropertyCount(), 60)).Select(i => sh.GetPropertyName(i))) + ".");
            var type = sh.GetPropertyType(idx);
            var value = a["value"];
            var before = MaterialInfo(mat)["properties"] as List<object>;
            object old = before.OfType<D>().FirstOrDefault(p => (string)p["name"] == name)?["value"];
            Undo.RecordObject(mat, "JARVIS material property");
            switch (type)
            {
                case UnityEngine.Rendering.ShaderPropertyType.Float:
                    Require(value is double, "invalidValue", "A number is required."); mat.SetFloat(name, (float)(double)value); break;
                case UnityEngine.Rendering.ShaderPropertyType.Range:
                {
                    Require(value is double, "invalidValue", "A number is required.");
                    var lim = sh.GetPropertyRangeLimits(idx);
                    Require((double)value >= lim.x - 1e-6 && (double)value <= lim.y + 1e-6, "invalidValue", "\"" + name + "\" accepts values between " + lim.x + " and " + lim.y + ".");
                    mat.SetFloat(name, (float)(double)value); break;
                }
                case UnityEngine.Rendering.ShaderPropertyType.Int: Require(value is double dv && dv == Math.Floor(dv), "invalidValue", "An integer is required."); mat.SetInteger(name, (int)(double)value); break;
                case UnityEngine.Rendering.ShaderPropertyType.Color: mat.SetColor(name, ColorOf(value, name)); break;
                case UnityEngine.Rendering.ShaderPropertyType.Vector: { var n = Nums(value, 4); mat.SetVector(name, new Vector4(n[0], n[1], n[2], n[3])); break; }
                case UnityEngine.Rendering.ShaderPropertyType.Texture:
                {
                    Texture t = null;
                    if (value is string ts && ts.Length > 0) { t = LoadAssetRef(ts, name) as Texture; Require(t != null, "typeMismatch", "The asset is not a Texture."); }
                    mat.SetTexture(name, t); break;
                }
                default: throw new OpException("propertyNotRepresentable", "Properties of type " + type + " cannot be edited through the bridge.");
            }
            EditorUtility.SetDirty(mat);
            AssetDatabase.SaveAssetIfDirty(mat);
            var after = MaterialInfo(mat)["properties"] as List<object>;
            object now = after.OfType<D>().FirstOrDefault(p => (string)p["name"] == name)?["value"];
            bool changed = Json.Serialize(old) != Json.Serialize(now);
            return Obj("changed", changed, "alreadyApplied", !changed, "property", name, "type", type.ToString(), "before", old, "value", now, "assetPath", path);
        }

        // ================================================================ animation

        static D CreateAnimatorController(D a)
        {
#if JARVIS_ANIMATION
            string path = Str(a, "assetPath");
            Require(AssetPathOk(path, ".controller"), "invalidArguments", "assetPath must be a new .controller inside Assets/.");
            Require(!File.Exists(Abs(path)), "assetExists", "A controller already exists at that path; the bridge never overwrites assets.");
            Directory.CreateDirectory(Path.GetDirectoryName(Abs(path)));
            var c = AnimatorController.CreateAnimatorControllerAtPath(path);
            Require(c != null, "createFailed", "Unity could not create the controller.");
            AssetDatabase.SaveAssets();
            var d = ControllerInfo(c); d["created"] = true; d["assetPath"] = path;
            return d;
#else
            throw new OpException("moduleMissing", "The Animation module is not enabled in this project.");
#endif
        }

        /// <summary>V0.13.1 — a deterministic clip: ONE transform property moved linearly along one axis (the fixture of the animation experiment). Whitelisted properties only; never overwrites.</summary>
        static D CreateAnimationClip(D a)
        {
#if JARVIS_ANIMATION
            string path = Str(a, "assetPath");
            Require(AssetPathOk(path, ".anim"), "invalidArguments", "assetPath must be a new .anim inside Assets/.");
            Require(!File.Exists(Abs(path)), "assetExists", "A clip already exists at that path; the bridge never overwrites assets.");
            string prop = Str(a, "property"), axis = Str(a, "axis");
            Require(prop == "position" || prop == "rotation" || prop == "scale", "invalidArguments", "property must be position, rotation or scale.");
            Require(axis == "x" || axis == "y" || axis == "z", "invalidArguments", "axis must be x, y or z.");
            float from = F(a, "from"), to = F(a, "to"), dur = F(a, "duration");
            Require(dur >= 0.1f && dur <= 60f && Mathf.Abs(from) <= 10000f && Mathf.Abs(to) <= 10000f, "invalidValue", "duration must be 0.1–60 s and from/to within ±10000.");
            bool loop = !a.ContainsKey("loop") || B(a, "loop");
            Directory.CreateDirectory(Path.GetDirectoryName(Abs(path)));
            var clip = new AnimationClip { name = Path.GetFileNameWithoutExtension(path) };
            string binding = (prop == "position" ? "localPosition." : prop == "rotation" ? "localEulerAnglesRaw." : "localScale.") + axis;
            clip.SetCurve("", typeof(Transform), binding, AnimationCurve.Linear(0f, from, dur, to));
            var settings = AnimationUtility.GetAnimationClipSettings(clip);
            settings.loopTime = loop;
            AnimationUtility.SetAnimationClipSettings(clip, settings);
            AssetDatabase.CreateAsset(clip, path);
            AssetDatabase.SaveAssets();
            var back = AssetDatabase.LoadAssetAtPath<AnimationClip>(path);
            Require(back != null, "createFailed", "Unity could not create the clip.");
            return Obj("created", true, "assetPath", path, "length", (double)back.length, "loop", back.isLooping, "property", binding);
#else
            throw new OpException("moduleMissing", "The Animation module is not enabled in this project.");
#endif
        }

        static D EditAnimatorController(D a)
        {
#if JARVIS_ANIMATION
            string path = Str(a, "assetPath");
            Require(AssetPathOk(path, ".controller"), "invalidArguments", "assetPath must be a .controller inside Assets/.");
            var c = AssetDatabase.LoadAssetAtPath<AnimatorController>(path);
            Require(c != null, "assetNotFound", "No Animator Controller exists at " + path + ".");
            string action = Str(a, "action");
            int layer = Int(a, "layer", 0);
            Require(layer >= 0 && layer < c.layers.Length, "invalidArguments", "layer " + layer + " does not exist (the controller has " + c.layers.Length + ").");
            var sm = c.layers[layer].stateMachine;
            bool changed = true;
            Func<string, AnimatorState> findState = n => { var s = sm.states.Select(x => x.state).FirstOrDefault(x => x.name == n); Require(s != null, "stateNotFound", "No state named \"" + n + "\" exists in layer " + layer + "."); return s; };
            Func<string, Motion> motionOf = m => { if (string.IsNullOrEmpty(m)) return null; var o = LoadAssetRef(m, "motion"); Require(o is Motion, "typeMismatch", "\"" + m + "\" is not an animation clip or blend tree."); return (Motion)o; };
            Func<string, AnimatorControllerParameter> param = n => { var p = c.parameters.FirstOrDefault(x => x.name == n); Require(p != null, "parameterNotFound", "The controller has no parameter named \"" + n + "\". It has: " + string.Join(", ", c.parameters.Select(x => x.name)) + "."); return p; };
            Undo.RecordObject(c, "JARVIS edit animator controller");
            switch (action)
            {
                case "addParameter":
                {
                    string n = Str(a, "name"); Require(!string.IsNullOrEmpty(n) && n.Length <= 60, "invalidArguments", "A parameter name is required.");
                    if (c.parameters.Any(p => p.name == n)) { changed = false; break; }
                    var t = EnumOf<AnimatorControllerParameterType>(Str(a, "type", "Float"), "parameter type");
                    var p = new AnimatorControllerParameter { name = n, type = t };
                    if (a.ContainsKey("default")) { if (t == AnimatorControllerParameterType.Float) p.defaultFloat = F(a, "default"); else if (t == AnimatorControllerParameterType.Int) p.defaultInt = (int)Num(a, "default"); else p.defaultBool = B(a, "default"); }
                    c.AddParameter(p); break;
                }
                case "addState":
                {
                    string n = Str(a, "name"); Require(!string.IsNullOrEmpty(n) && n.Length <= 60, "invalidArguments", "A state name is required.");
                    if (sm.states.Any(x => x.state.name == n)) { changed = false; break; }
                    var st = sm.AddState(n);
                    if (Has(a, "motion")) st.motion = motionOf(S(a, "motion"));
                    if (Has(a, "speed")) { var v = F(a, "speed"); Require(v >= -10 && v <= 10, "invalidValue", "speed must be between -10 and 10."); st.speed = v; }
                    break;
                }
                case "setDefaultState": { var st = findState(Str(a, "name")); if (sm.defaultState == st) { changed = false; break; } sm.defaultState = st; break; }
                case "setStateSpeed": { var st = findState(Str(a, "name")); var v = F(a, "speed"); Require(v >= -10 && v <= 10, "invalidValue", "speed must be between -10 and 10."); if (Math.Abs(st.speed - v) < 1e-6) { changed = false; break; } st.speed = v; break; }
                case "setStateMotion": { var st = findState(Str(a, "name")); var m = motionOf(Str(a, "motion")); if (st.motion == m) { changed = false; break; } st.motion = m; break; }
                case "addTransition":
                {
                    string from = Str(a, "from"), to = Str(a, "to");
                    var dest = findState(to);
                    var conditions = Arr(a, "conditions") ?? new List<object>();
                    Require(conditions.Count <= 6, "invalidArguments", "A transition takes at most 6 conditions.");
                    bool any = from == "Any";
                    var src = any ? null : findState(from);
                    var existing = any ? sm.anyStateTransitions.Where(t => t.destinationState == dest) : src.transitions.Where(t => t.destinationState == dest);
                    if (existing.Any()) { changed = false; break; }
                    var tr = any ? sm.AddAnyStateTransition(dest) : src.AddTransition(dest);
                    tr.hasExitTime = Bool(a, "hasExitTime", !any && conditions.Count == 0);
                    if (Has(a, "exitTime")) tr.exitTime = F(a, "exitTime");
                    tr.duration = Has(a, "duration") ? F(a, "duration") : 0.1f;
                    foreach (var co in conditions.OfType<D>())
                    {
                        var p = param(Str(co, "parameter"));
                        var mode = EnumOf<AnimatorConditionMode>(Str(co, "mode", p.type == AnimatorControllerParameterType.Bool || p.type == AnimatorControllerParameterType.Trigger ? "If" : "Greater"), "condition mode");
                        tr.AddCondition(mode, Has(co, "threshold") ? F(co, "threshold") : 0f, p.name);
                    }
                    break;
                }
                case "addBlendTreeState":
                {
                    string n = Str(a, "name"); Require(!string.IsNullOrEmpty(n), "invalidArguments", "A state name is required.");
                    if (sm.states.Any(x => x.state.name == n)) { changed = false; break; }
                    var bp = param(Str(a, "parameter"));
                    Require(bp.type == AnimatorControllerParameterType.Float, "invalidArguments", "A blend tree needs a Float parameter.");
                    BlendTree tree;
                    var st = c.CreateBlendTreeInController(n, out tree, layer);
                    tree.blendType = BlendTreeType.Simple1D; tree.blendParameter = bp.name;
                    foreach (var ch in (Arr(a, "children") ?? new List<object>()).OfType<D>().Take(8)) tree.AddChild(motionOf(Str(ch, "motion")), F(ch, "threshold"));
                    break;
                }
                default: throw new OpException("unknownAction", "\"" + action + "\" is not a supported controller action. Supported: addParameter, addState, setDefaultState, setStateSpeed, setStateMotion, addTransition, addBlendTreeState.");
            }
            if (changed) { EditorUtility.SetDirty(c); AssetDatabase.SaveAssetIfDirty(c); }
            var d = ControllerInfo(c); d["changed"] = changed; d["alreadyApplied"] = !changed; d["action"] = action; d["assetPath"] = path;
            return d;
#else
            throw new OpException("moduleMissing", "The Animation module is not enabled in this project.");
#endif
        }

        static D SetModelImporter(D a)
        {
            string path = Str(a, "assetPath");
            Require(AssetPathOk(path), "invalidArguments", "assetPath must be a model asset inside Assets/.");
            var mi = AssetImporter.GetAtPath(path) as ModelImporter;
            Require(mi != null, "notAModel", path + " is not imported as a model.");
            var s = Sub(a, "settings");
            Require(s != null && s.Count > 0, "invalidArguments", "settings are required.");
            NeedKeys(s, "model importer", "animationType", "importAnimation", "optimizeGameObjects", "isReadable", "clipLoop");
            var previous = ModelInfo(path, mi);
            bool dirty = false;
            if (s.ContainsKey("animationType")) { var v = EnumOf<ModelImporterAnimationType>(s["animationType"], "animationType"); if (mi.animationType != v) { mi.animationType = v; dirty = true; } }
            if (s.ContainsKey("importAnimation")) { var v = B(s, "importAnimation"); if (mi.importAnimation != v) { mi.importAnimation = v; dirty = true; } }
            if (s.ContainsKey("optimizeGameObjects")) { var v = B(s, "optimizeGameObjects"); if (mi.optimizeGameObjects != v) { mi.optimizeGameObjects = v; dirty = true; } }
            if (s.ContainsKey("isReadable")) { var v = B(s, "isReadable"); if (mi.isReadable != v) { mi.isReadable = v; dirty = true; } }
            if (s.ContainsKey("clipLoop"))
            {
                var cl = s["clipLoop"] as List<object>;
                Require(cl != null && cl.Count == 2 && cl[0] is string && cl[1] is bool, "invalidValue", "clipLoop needs [clip name, true|false].");
                var clips = (mi.clipAnimations != null && mi.clipAnimations.Length > 0 ? mi.clipAnimations : mi.defaultClipAnimations).ToArray();
                int i = Array.FindIndex(clips, x => x.name == (string)cl[0]);
                Require(i >= 0, "clipNotFound", "The model has no clip named \"" + (string)cl[0] + "\". It has: " + string.Join(", ", clips.Select(x => x.name)) + ".");
                if (clips[i].loopTime != (bool)cl[1]) { clips[i].loopTime = (bool)cl[1]; mi.clipAnimations = clips; dirty = true; }
            }
            if (dirty) mi.SaveAndReimport();                    // intentional, visible re-import
            var after = ModelInfo(path, AssetImporter.GetAtPath(path) as ModelImporter);
            return Obj("changed", dirty, "alreadyApplied", !dirty, "reimported", dirty, "previous", previous, "after", after, "assetPath", path);
        }

        // ================================================================ runtime snapshot (allowed in Play Mode; reads only)

        static D InspectRuntime(D a)
        {
            var targets = Arr(a, "targets")?.OfType<D>().Take(12).ToList() ?? new List<D>();
            Require(targets.Count > 0, "invalidArguments", "At least one target is required.");
            var states = Arr(a, "animatorStates")?.OfType<string>().Take(12).ToList() ?? new List<string>();
            var list = new List<object>();
            foreach (var t in targets)
            {
                GameObject go = null;
                try { go = Resolve(t, true); } catch (OpException e) when (e.Code == "targetNotFound") { list.Add(Obj("exists", false)); continue; }
                var d = Obj("exists", true, "object", Identity(go), "pose", Pose(go), "activeInHierarchy", go.activeInHierarchy);
                var rends = go.GetComponentsInChildren<Renderer>(false);
                d["renderers"] = rends.Length; d["visibleToAnyCamera"] = rends.Any(r => r.isVisible);
#if JARVIS_PHYSICS
                var rb = go.GetComponent<Rigidbody>();
                if (rb != null) d["rigidbody"] = Obj("velocity", Vec(rb.linearVelocity), "speed", (double)rb.linearVelocity.magnitude, "isKinematic", rb.isKinematic, "sleeping", rb.IsSleeping());
#endif
#if JARVIS_ANIMATION
                var an = go.GetComponentInChildren<Animator>();
                if (an != null)
                {
                    var info = Obj("enabled", an.enabled, "hasController", an.runtimeAnimatorController != null, "controller", an.runtimeAnimatorController == null ? null : an.runtimeAnimatorController.name, "speed", (double)an.speed,
                                   "applyRootMotion", an.applyRootMotion, "isHuman", an.isHuman);
                    if (EditorApplication.isPlaying && an.isActiveAndEnabled && an.runtimeAnimatorController != null)
                    {
                        var st = an.GetCurrentAnimatorStateInfo(0);
                        var inState = new D();
                        foreach (var n in states) inState[n] = st.IsName(n);
                        info["normalizedTime"] = (double)st.normalizedTime; info["isInTransition"] = an.IsInTransition(0); info["inState"] = inState;
                        info["clips"] = an.GetCurrentAnimatorClipInfo(0).Select(ci => (object)ci.clip.name).Take(6).ToList();
                        info["parameters"] = an.parameters.Where(p => p.type != AnimatorControllerParameterType.Trigger).Take(12).Select(p => (object)Obj("name", p.name, "value", p.type == AnimatorControllerParameterType.Float ? (double)an.GetFloat(p.name) : p.type == AnimatorControllerParameterType.Int ? (double)an.GetInteger(p.name) : (object)an.GetBool(p.name))).ToList();
                    }
                    d["animator"] = info;
                }
#endif
#if JARVIS_AUDIO
                var au = go.GetComponentInChildren<AudioSource>();
                if (au != null) d["audio"] = Obj("enabled", au.enabled, "isPlaying", au.isPlaying, "clip", AssetRefOf(au.clip), "volume", (double)au.volume, "mute", au.mute, "loop", au.loop, "time", (double)au.time, "spatialBlend", (double)au.spatialBlend);
#endif
                list.Add(d);
            }
            return Obj("playing", EditorApplication.isPlaying, "time", EditorApplication.isPlaying ? (double)Time.time : 0.0, "frame", EditorApplication.isPlaying ? Time.frameCount : 0, "targets", list);
        }

        // ================================================================ camera capture (a render of the Game camera; no desktop, no editor chrome)

        static string CapturesDir => Path.Combine(JarvisBridge.Root, "captures");

        static D CaptureView(D a)
        {
            int w = Math.Min(Math.Max(Int(a, "width", 640), 64), 1280), h = Math.Min(Math.Max(Int(a, "height", 360), 64), 1280);
            Camera cam = null;
            if (a.ContainsKey("camera") && a["camera"] is D cd) cam = Resolve(cd, true).GetComponent<Camera>();
            else
            {
                cam = Camera.main;
                if (cam == null) cam = Object.FindObjectsByType<Camera>(FindObjectsInactive.Exclude, FindObjectsSortMode.None).Where(c => c.enabled && c.targetTexture == null).OrderByDescending(c => c.depth).FirstOrDefault();
            }
            Require(cam != null, "noCamera", "No enabled camera exists in the loaded scenes to render.");
            Require(SystemInfo.graphicsDeviceType != UnityEngine.Rendering.GraphicsDeviceType.Null, "noGraphicsDevice", "This editor runs without a graphics device (-nographics); it cannot render a camera.");
            Directory.CreateDirectory(CapturesDir);
            try { foreach (var f in Directory.GetFiles(CapturesDir, "*.png")) if ((DateTime.UtcNow - File.GetLastWriteTimeUtc(f)).TotalMinutes > 10) File.Delete(f); } catch (Exception) { }

            var prevTarget = cam.targetTexture;
            var rt = RenderTexture.GetTemporary(w, h, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB);
            var prevActive = RenderTexture.active;
            Texture2D tex;
            try
            {
                cam.targetTexture = rt;
                cam.Render();
                RenderTexture.active = rt;
                tex = new Texture2D(w, h, TextureFormat.RGBA32, false);
                tex.ReadPixels(new Rect(0, 0, w, h), 0, 0);
                tex.Apply();
            }
            finally { cam.targetTexture = prevTarget; RenderTexture.active = prevActive; RenderTexture.ReleaseTemporary(rt); }

            var px = tex.GetPixels32();
            int n = px.Length;
            var lum = new float[n];
            double sum = 0, sum2 = 0; int dark = 0, bright = 0;
            for (int i = 0; i < n; i++)
            {
                float l = (0.2126f * px[i].r + 0.7152f * px[i].g + 0.0722f * px[i].b) / 255f;
                lum[i] = l; sum += l; sum2 += l * l;
                if (l < 0.05f) dark++; else if (l > 0.95f) bright++;
            }
            double mean = sum / n, sd = Math.Sqrt(Math.Max(0, sum2 / n - mean * mean));
            var sorted = (float[])lum.Clone(); Array.Sort(sorted);
            string file = Guid.NewGuid().ToString("N") + ".png";
#if JARVIS_IMAGECONVERSION
            File.WriteAllBytes(Path.Combine(CapturesDir, file), tex.EncodeToPNG());
#else
            Object.DestroyImmediate(tex);
            throw new OpException("moduleMissing", "The Image Conversion module is not enabled in this project; the capture cannot be encoded.");
#endif
            Object.DestroyImmediate(tex);

            var analysis = new List<object>();
            foreach (var td in (Arr(a, "targets") ?? new List<object>()).OfType<D>().Take(8))
            {
                GameObject go = null;
                try { go = Resolve(td, true); } catch (OpException e) when (e.Code == "targetNotFound") { analysis.Add(Obj("exists", false)); continue; }
                var rs = go.GetComponentsInChildren<Renderer>(false).Where(r => r.enabled).ToList();
                if (rs.Count == 0) { analysis.Add(Obj("exists", true, "object", HierarchyPath(go.transform, true), "renderers", 0, "inFrustum", false, "visible", false, "reason", "no enabled renderer")); continue; }
                var b = rs[0].bounds; foreach (var r in rs.Skip(1)) b.Encapsulate(r.bounds);
                bool inFrustum = GeometryUtility.TestPlanesAABB(GeometryUtility.CalculateFrustumPlanes(cam), b);
                float minx = 1, miny = 1, maxx = 0, maxy = 0; bool behind = false;
                for (int i = 0; i < 8; i++)
                {
                    var c = new Vector3(i % 2 == 0 ? b.min.x : b.max.x, (i / 2) % 2 == 0 ? b.min.y : b.max.y, i / 4 == 0 ? b.min.z : b.max.z);
                    var v = cam.WorldToViewportPoint(c);
                    if (v.z <= 0) { behind = true; continue; }
                    minx = Math.Min(minx, v.x); maxx = Math.Max(maxx, v.x); miny = Math.Min(miny, v.y); maxy = Math.Max(maxy, v.y);
                }
                minx = Mathf.Clamp01(minx); maxx = Mathf.Clamp01(maxx); miny = Mathf.Clamp01(miny); maxy = Mathf.Clamp01(maxy);
                double area = Math.Max(0, maxx - minx) * Math.Max(0, maxy - miny);
                double region = double.NaN, rest = double.NaN, contrast = 0;
                if (area > 0)
                {
                    int x0 = (int)(minx * (w - 1)), x1 = (int)(maxx * (w - 1)), y0 = (int)(miny * (h - 1)), y1 = (int)(maxy * (h - 1));
                    double rs2 = 0; int rn = 0;
                    for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) { rs2 += lum[y * w + x]; rn++; }
                    if (rn > 0 && n - rn > 0) { region = rs2 / rn; rest = (sum - rs2) / (n - rn); contrast = Math.Abs(region - rest); }
                }
                bool visible = inFrustum && area >= 0.001 && contrast >= 0.03;
                analysis.Add(Obj("exists", true, "object", HierarchyPath(go.transform, true), "renderers", rs.Count, "inFrustum", inFrustum, "partlyBehindCamera", behind, "viewport", new List<object> { (double)minx, (double)miny, (double)maxx, (double)maxy },
                                 "areaFraction", area, "regionLuminance", double.IsNaN(region) ? null : (object)region, "restLuminance", double.IsNaN(rest) ? null : (object)rest, "contrast", contrast, "visible", visible));
            }
            return Obj("file", "captures/" + file, "width", w, "height", h, "camera", HierarchyPath(cam.transform, true), "isPlaying", EditorApplication.isPlaying,
                       "luminance", Obj("mean", mean, "stddev", sd, "p5", (double)sorted[(int)(n * 0.05)], "p50", (double)sorted[n / 2], "p95", (double)sorted[Math.Min(n - 1, (int)(n * 0.95))], "darkFraction", (double)dark / n, "brightFraction", (double)bright / n),
                       "targets", analysis);
        }
    }
}
