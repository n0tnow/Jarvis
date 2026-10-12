using UnityEngine;

/// <summary>Fixture component for the Console scenarios: logs an error (with synthetic, secret-looking text) when Play Mode starts.</summary>
public class ErrorEmitter : MonoBehaviour
{
    void Start()
    {
        // Built at runtime so the repository never contains a contiguous key-shaped string.
        var key = "sk-" + "proj-FAKE0123456789abcdefghijkl";
        Debug.LogError("Fixture synthetic error: api_key=" + key + " password=hunter2-fake");
    }
}
