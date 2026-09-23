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
    ("A click with the arrow tool creates no annotation", () =>
    {
        var session = new AnnotationSession();
        Equal(false, session.Add(new Annotation(AnnotationKind.Arrow,
            new PointI(10, 10), new PointI(10, 10), default, "", 0xFFFF0000, 3, 1)));
        Equal(0, session.Annotations.Count);
    }),
    ("A one-pixel rectangle creates no annotation", () =>
    {
        var session = new AnnotationSession();
        Equal(false, session.Add(new Annotation(AnnotationKind.Rectangle,
            default, default, new RectangleI(10, 10, 1, 1), "", 0xFFFF0000, 3, 1)));
    }),
    ("Undo and redo restore a drawn arrow", () =>
    {
        var session = new AnnotationSession();
        session.Add(new Annotation(AnnotationKind.Arrow,
            new PointI(10, 10), new PointI(40, 50), default, "", 0xFFFF0000, 3, 1));
        Equal(1, session.Annotations.Count);
        session.Undo();
        Equal(0, session.Annotations.Count);
        session.Redo();
        Equal(1, session.Annotations.Count);
    }),
    ("A new edit invalidates redo", () =>
    {
        var session = new AnnotationSession();
        session.Add(new Annotation(AnnotationKind.Arrow,
            new PointI(10, 10), new PointI(40, 50), default, "", 0xFFFF0000, 3, 1));
        session.Undo();
        session.Add(new Annotation(AnnotationKind.Rectangle,
            default, default, new RectangleI(1, 1, 20, 20), "", 0xFF00FF00, 3, 1));
        session.Redo();
        Equal(AnnotationKind.Rectangle, session.Annotations[0].Kind);
        Equal(1, session.Annotations.Count);
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
