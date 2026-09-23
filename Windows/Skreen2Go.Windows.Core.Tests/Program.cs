using Skreen2Go.Windows.Core;
using Skreen2Go.Windows;
using System.Drawing;

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
    ("Rendered annotation keeps source dimensions and colored pixels", () =>
    {
        using var source = new Bitmap(200, 100);
        using (var graphics = Graphics.FromImage(source)) graphics.Clear(Color.White);
        var arrow = new Annotation(AnnotationKind.Arrow,
            new PointI(10, 10), new PointI(50, 10), default, "", 0xFFFF0000, 3, 1);
        using var result = ImageOutput.Render(source, [arrow]);
        Equal(200, result.Width);
        Equal(100, result.Height);
        var pixel = result.GetPixel(25, 10);
        if (pixel.R < 200 || pixel.G > 80 || pixel.B > 80)
            throw new Exception($"Expected red arrow pixel at (25,10), got {pixel}");
    }),
    ("Save as replaces a confirmed existing image", () =>
    {
        var folder = Path.Combine(Path.GetTempPath(), "Skreen2GoTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var path = Path.Combine(folder, "image.png");
            using var oldImage = new Bitmap(1, 1);
            oldImage.SetPixel(0, 0, Color.Blue);
            oldImage.Save(path);
            using var newImage = new Bitmap(2, 2);
            using (var graphics = Graphics.FromImage(newImage)) graphics.Clear(Color.Red);
            ImageOutput.Save(newImage, path, overwrite: true);
            using var saved = new Bitmap(path);
            Equal(2, saved.Width);
            Equal(Color.Red.ToArgb(), saved.GetPixel(0, 0).ToArgb());
        }
        finally { Directory.Delete(folder, recursive: true); }
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
