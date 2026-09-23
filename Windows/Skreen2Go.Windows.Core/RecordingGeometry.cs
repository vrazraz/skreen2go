namespace Skreen2Go.Windows.Core;

public readonly record struct RecordingDisplay(string Name, RectangleI Bounds);

public readonly record struct RecordingPlan(
    string DisplayName, RectangleI SourceRect, bool TrimmedToOneDisplay)
{
    public int PixelWidth => SourceRect.Width;
    public int PixelHeight => SourceRect.Height;
}

public static class RecordingGeometry
{
    public static RecordingPlan Plan(RectangleI selection,
        IReadOnlyList<RecordingDisplay> displays)
    {
        if (selection.IsEmpty || displays.Count == 0)
            throw new ArgumentException("Select an area inside a display.", nameof(selection));

        var bestArea = 0L;
        RecordingDisplay? bestDisplay = null;
        RectangleI bestOverlap = default;
        foreach (var display in displays)
        {
            var overlap = SelectionGeometry.Clamp(selection, display.Bounds);
            var area = (long)overlap.Width * overlap.Height;
            if (area <= bestArea) continue;
            bestArea = area;
            bestDisplay = display;
            bestOverlap = overlap;
        }

        if (bestDisplay is null || bestOverlap.Width < 2 || bestOverlap.Height < 2)
            throw new ArgumentException("The selected recording area is too small.", nameof(selection));

        var width = bestOverlap.Width & ~1;
        var height = bestOverlap.Height & ~1;
        var local = new RectangleI(bestOverlap.X - bestDisplay.Value.Bounds.X,
            bestOverlap.Y - bestDisplay.Value.Bounds.Y, width, height);
        return new RecordingPlan(bestDisplay.Value.Name, local,
            bestOverlap != selection);
    }
}
