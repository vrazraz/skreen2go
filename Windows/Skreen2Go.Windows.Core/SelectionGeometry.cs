namespace Skreen2Go.Windows.Core;

public readonly record struct PointI(int X, int Y);

public readonly record struct RectangleI(int X, int Y, int Width, int Height)
{
    public int Right => X + Width;
    public int Bottom => Y + Height;
    public bool IsEmpty => Width <= 0 || Height <= 0;
}

public static class SelectionGeometry
{
    public static RectangleI Normalize(PointI start, PointI end)
    {
        var left = Math.Min(start.X, end.X);
        var top = Math.Min(start.Y, end.Y);
        return new RectangleI(left, top, Math.Abs(start.X - end.X), Math.Abs(start.Y - end.Y));
    }

    public static RectangleI Clamp(RectangleI selection, RectangleI bounds)
    {
        var left = Math.Max(selection.X, bounds.X);
        var top = Math.Max(selection.Y, bounds.Y);
        var right = Math.Min(selection.Right, bounds.Right);
        var bottom = Math.Min(selection.Bottom, bounds.Bottom);
        return new RectangleI(left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));
    }

    public static RectangleI ToBitmapLocal(RectangleI selection, RectangleI desktopBounds)
    {
        var clipped = Clamp(selection, desktopBounds);
        return new RectangleI(clipped.X - desktopBounds.X, clipped.Y - desktopBounds.Y,
            clipped.Width, clipped.Height);
    }
}
