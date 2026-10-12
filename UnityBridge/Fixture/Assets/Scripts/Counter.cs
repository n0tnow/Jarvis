using UnityEngine;

/// <summary>Disposable fixture component: copies startValue to value when the scene starts.</summary>
public class Counter : MonoBehaviour
{
    public int startValue = 1;
    public int value;
    public string label = "fixture";

    void Start() { value = startValue; }
}
