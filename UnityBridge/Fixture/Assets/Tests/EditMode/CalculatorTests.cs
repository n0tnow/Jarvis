using NUnit.Framework;

public class CalculatorTests
{
    [Test] public void Add_ReturnsSum() { Assert.AreEqual(5, Calculator.Add(2, 3)); }
    [Test] public void Add_HandlesNegatives() { Assert.AreEqual(-1, Calculator.Add(2, -3)); }
}
