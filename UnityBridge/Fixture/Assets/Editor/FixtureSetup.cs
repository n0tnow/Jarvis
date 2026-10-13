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

    static FixtureSetup()
    {
        EditorApplication.update += Poll;
        EditorApplication.delayCall += EnsureAnimationClip;
        EditorApplication.delayCall += EnsureAudioClip;
    }

    /// <summary>Fixture-only: a half-second 440 Hz tone written as a plain 16-bit mono WAV by code (no audio file is committed to the repository).</summary>
    static void EnsureAudioClip()
    {
        const string path = "Assets/Audio/beep.wav";
        if (File.Exists(path)) return;
        Directory.CreateDirectory("Assets/Audio");
        const int rate = 22050, n = rate / 2;
        using (var w = new BinaryWriter(File.Create(path)))
        {
            w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + n * 2); w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
            w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
            w.Write(System.Text.Encoding.ASCII.GetBytes("data")); w.Write(n * 2);
            for (int i = 0; i < n; i++) w.Write((short)(12000 * Mathf.Sin(2 * Mathf.PI * 440 * i / rate) * (1f - (float)i / n)));
        }
        AssetDatabase.ImportAsset(path);
    }

    /// <summary>Fixture-only: a one-second looping clip that slides a Transform along x from 0 to 2 (built through the Animation API so the binding is exactly what Unity itself writes).</summary>
    static void EnsureAnimationClip()
    {
        const string path = "Assets/Animation/Slide.anim";
        if (File.Exists(path)) return;
        Directory.CreateDirectory("Assets/Animation");
        var clip = new AnimationClip { name = "Slide", frameRate = 30 };
        clip.SetCurve("", typeof(Transform), "localPosition.x", AnimationCurve.Linear(0, 0, 1, 2));
        var settings = AnimationUtility.GetAnimationClipSettings(clip);
        settings.loopTime = true;
        AnimationUtility.SetAnimationClipSettings(clip, settings);
        AssetDatabase.CreateAsset(clip, path);
        AssetDatabase.SaveAssets();
    }

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
