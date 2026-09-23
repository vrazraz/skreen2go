namespace Skreen2Go.Windows.Core;

public static class WindowSelection
{
    public static RectangleI? Pick(PointI point, IReadOnlyList<RectangleI> topToBottom)
    {
        foreach (var window in topToBottom)
        {
            if (window.IsEmpty) continue;
            if (point.X >= window.X && point.X < window.Right &&
                point.Y >= window.Y && point.Y < window.Bottom)
                return window;
        }
        return null;
    }
}
