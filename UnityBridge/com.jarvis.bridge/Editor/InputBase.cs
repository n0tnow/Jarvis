using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;

namespace Jarvis.Bridge
{
    using D = Dictionary<string, object>;

    /// <summary>
    /// V0.13.1 — the Input System operations that exist even when the package is NOT installed: they say so (package + version, the project's .inputactions assets) and every
    /// edit answers inputSystemMissing. The real implementation lives in the optional Jarvis.Bridge.InputSystem assembly (compiled only when com.unity.inputsystem is installed),
    /// which re-registers these names with the full behaviour.
    /// </summary>
    internal static partial class Ops
    {
        static void RegisterInputBase(Action<string, JarvisBridge.Handler, bool> R)
        {
            R("inspectInput", InspectInputBase, false);
            foreach (var op in new[] { "createInputAsset", "createInputMap", "createInputAction", "addInputBinding", "changeInputBinding", "removeInputBinding" })
                R(op, a => throw new OpException("inputSystemMissing", "The Input System package (com.unity.inputsystem) is not installed in this project, so input actions cannot be edited. JARVIS does not install packages."), true);
        }

        static D InspectInputBase(D a)
        {
            var info = UnityEditor.PackageManager.PackageInfo.FindForAssetPath("Packages/com.unity.inputsystem");
            var assets = new List<object>();
            var root = Path.Combine(JarvisBridge.ProjectPath, "Assets");
            if (Directory.Exists(root))
                foreach (var f in Directory.GetFiles(root, "*.inputactions", SearchOption.AllDirectories).OrderBy(x => x, StringComparer.Ordinal).Take(50))
                    assets.Add("Assets/" + f.Substring(root.Length + 1).Replace('\\', '/'));
            return Obj("package", Obj("installed", info != null, "version", info != null ? info.version : null), "assets", assets,
                       "note", info == null ? "The Input System package is not installed; only the asset list is available." : "The Input System package is installed but its editor assembly is not loaded yet (compiling?).");
        }
    }
}
