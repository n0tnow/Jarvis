using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

/// <summary>
/// Fixture-only editor helpers (NOT part of the JARVIS bridge): CreateScene builds FixtureScene once; the trigger file simulates "the user
/// typed something in the editor" (an unsaved change) so the dirty-scene protection can be exercised for real.
/// </summary>
[InitializeOnLoad]
public static class FixtureSetup
{
    static double next;

    static FixtureSetup() { EditorApplication.update += Poll; }

    static void Poll()
    {
        if (EditorApplication.timeSinceStartup < next) return;
        next = EditorApplication.timeSinceStartup + 0.25;
        var dir = Path.Combine(Directory.GetParent(Application.dataPath).FullName, "Library", "JarvisFixture");
        var logTrigger = Path.Combine(dir, "log-error");
        if (File.Exists(logTrigger))
        {
            var text = File.ReadAllText(logTrigger);
            File.Delete(logTrigger);
            Debug.LogError(text);
        }
        var trigger = Path.Combine(dir, "make-dirty");
        if (!File.Exists(trigger) || EditorApplication.isPlaying) return;
        File.Delete(trigger);
        var cube = GameObject.Find("TestCube");
        if (cube != null)
        {
            cube.transform.position += new Vector3(0, 0.5f, 0);
            EditorSceneManager.MarkSceneDirty(cube.scene);
        }
    }

    [MenuItem("Fixture/Create Scene")]
    public static void CreateScene()
    {
        var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        var cam = new GameObject("Main Camera"); cam.AddComponent<Camera>(); cam.tag = "MainCamera";
        var cube = new GameObject("TestCube");
        cube.AddComponent<MeshFilter>().sharedMesh = Resources.GetBuiltinResource<Mesh>("Cube.fbx");
        cube.AddComponent<MeshRenderer>();
        var counter = new GameObject("CounterObject");
        counter.AddComponent<Counter>().startValue = 1;
        Directory.CreateDirectory("Assets/Scenes");
        EditorSceneManager.SaveScene(scene, "Assets/Scenes/FixtureScene.unity");
        AssetDatabase.SaveAssets();
    }
}
