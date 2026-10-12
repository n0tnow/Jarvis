using System.Collections;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

public class CounterPlayTests
{
    [UnityTest]
    public IEnumerator Counter_StartCopiesStartValue()
    {
        var go = new GameObject("PlayTestCounter");
        var c = go.AddComponent<Counter>();
        c.startValue = 7;
        yield return null;
        Assert.AreEqual(7, c.value);
        Object.Destroy(go);
    }
}
