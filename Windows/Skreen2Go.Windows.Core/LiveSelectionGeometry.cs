namespace Skreen2Go.Windows.Core;

public enum SelectionHandle
{
    TopLeft, Top, TopRight, Right, BottomRight, Bottom, BottomLeft, Left
}

public static class LiveSelectionGeometry
{
    public static RectangleI Move(RectangleI frame, int dx, int dy, RectangleI bounds) =>
        frame with
        {
            X = Math.Clamp(frame.X + dx, bounds.X, bounds.Right - frame.Width),
            Y = Math.Clamp(frame.Y + dy, bounds.Y, bounds.Bottom - frame.Height)
        };

    public static RectangleI Resize(RectangleI frame, SelectionHandle handle,
        PointI pointer, RectangleI bounds, int minimumSide = 8)
    {
        var left = frame.X;
        var top = frame.Y;
        var right = frame.Right;
        var bottom = frame.Bottom;
        if (handle is SelectionHandle.TopLeft or SelectionHandle.Left or SelectionHandle.BottomLeft)
            left = Math.Clamp(pointer.X, bounds.X, right - minimumSide);
        if (handle is SelectionHandle.TopRight or SelectionHandle.Right or SelectionHandle.BottomRight)
            right = Math.Clamp(pointer.X, left + minimumSide, bounds.Right);
        if (handle is SelectionHandle.TopLeft or SelectionHandle.Top or SelectionHandle.TopRight)
            top = Math.Clamp(pointer.Y, bounds.Y, bottom - minimumSide);
        if (handle is SelectionHandle.BottomLeft or SelectionHandle.Bottom or SelectionHandle.BottomRight)
            bottom = Math.Clamp(pointer.Y, top + minimumSide, bounds.Bottom);
        return new RectangleI(left, top, right - left, bottom - top);
    }

    public static SelectionHandle? HandleAt(RectangleI frame, PointI point, int tolerance = 10)
    {
        var middleX = frame.X + frame.Width / 2;
        var middleY = frame.Y + frame.Height / 2;
        var handles = new (SelectionHandle Handle, PointI Center)[]
        {
            (SelectionHandle.TopLeft, new(frame.X, frame.Y)),
            (SelectionHandle.Top, new(middleX, frame.Y)),
            (SelectionHandle.TopRight, new(frame.Right, frame.Y)),
            (SelectionHandle.Right, new(frame.Right, middleY)),
            (SelectionHandle.BottomRight, new(frame.Right, frame.Bottom)),
            (SelectionHandle.Bottom, new(middleX, frame.Bottom)),
            (SelectionHandle.BottomLeft, new(frame.X, frame.Bottom)),
            (SelectionHandle.Left, new(frame.X, middleY))
        };
        foreach (var (handle, center) in handles)
            if (Math.Abs(point.X - center.X) <= tolerance &&
                Math.Abs(point.Y - center.Y) <= tolerance)
                return handle;
        return null;
    }
}

public static class FloatingBarPlacement
{
    public static RectangleI Place(RectangleI selection, int barWidth, int barHeight,
        RectangleI bounds, int gap = 8)
    {
        var width = Math.Min(barWidth, bounds.Width);
        var height = Math.Min(barHeight, bounds.Height);
        var x = Math.Clamp(selection.X, bounds.X, bounds.Right - width);
        var y = Math.Clamp(selection.Y, bounds.Y, bounds.Bottom - height);
        var candidates = new[]
        {
            new RectangleI(x, selection.Bottom + gap, width, height),
            new RectangleI(selection.Right + gap, y, width, height),
            new RectangleI(x, selection.Y - gap - height, width, height),
            new RectangleI(selection.X - gap - width, y, width, height)
        };
        foreach (var candidate in candidates)
            if (candidate.X >= bounds.X && candidate.Y >= bounds.Y &&
                candidate.Right <= bounds.Right && candidate.Bottom <= bounds.Bottom)
                return candidate;
        return new RectangleI(
            Math.Clamp(selection.X + (selection.Width - width) / 2,
                bounds.X, bounds.Right - width),
            Math.Clamp(selection.Y + gap, bounds.Y, bounds.Bottom - height),
            width, height);
    }
}
