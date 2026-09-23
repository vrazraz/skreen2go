using Skreen2Go.Windows.Core;

var tests = new (string Name, Action Run)[]
{
    ("A reversed drag normalizes to positive dimensions", () =>
        Equal(new RectangleI(10, 20, 90, 60),
            SelectionGeometry.Normalize(new PointI(100, 80), new PointI(10, 20)))),
    ("Selection clamps to a virtual desktop with negative origin", () =>
        Equal(new RectangleI(-100, 0, 300, 250),
            SelectionGeometry.Clamp(new RectangleI(-200, -50, 400, 300),
                new RectangleI(-100, 0, 600, 400)))),
    ("Physical desktop selection maps to bitmap-local crop", () =>
        Equal(new RectangleI(50, 40, 150, 80),
            SelectionGeometry.ToBitmapLocal(new RectangleI(-450, 40, 150, 80),
                new RectangleI(-500, 0, 1000, 500)))),
    ("Two saves in one second get distinct names", () =>
    {
        var at = new DateTimeOffset(2026, 9, 23, 14, 30, 25, TimeSpan.Zero);
        var first = OutputNaming.NextPath("C:\\shots", "Screenshot", at, _ => false);
        var second = OutputNaming.NextPath("C:\\shots", "Screenshot", at, path => path == first);
        Equal("Screenshot 2026-09-23 at 14.30.25.png", Path.GetFileName(first));
        Equal("Screenshot 2026-09-23 at 14.30.25 (2).png", Path.GetFileName(second));
    }),
};

var failed = 0;
foreach (var (name, run) in tests)
{
    try { run(); Console.WriteLine($"PASS {name}"); }
    catch (Exception error) { failed++; Console.Error.WriteLine($"FAIL {name}: {error.Message}"); }
}

Console.WriteLine($"{tests.Length - failed}/{tests.Length} passed");
return failed == 0 ? 0 : 1;

static void Equal<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
        throw new Exception($"Expected {expected}, got {actual}");
}
