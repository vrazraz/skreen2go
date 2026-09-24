using System.Drawing;
using Skreen2Go.Windows.Core;

namespace Skreen2Go.Windows;

internal static class TextAnnotationLayout
{
    public static RectangleI Measure(string text, PointI origin, float fontSize, RectangleI bounds)
    {
        var availableWidth = Math.Max(1, Math.Min(340, bounds.Right - origin.X));
        var availableHeight = Math.Max(1, bounds.Bottom - origin.Y);
        using var image = new Bitmap(1, 1);
        using var graphics = Graphics.FromImage(image);
        using var font = new Font("Segoe UI", Math.Max(8, fontSize),
            FontStyle.Regular, GraphicsUnit.Pixel);
        var size = graphics.MeasureString(text, font, availableWidth,
            StringFormat.GenericTypographic);
        return new RectangleI(origin.X, origin.Y,
            Math.Clamp((int)Math.Ceiling(size.Width) + 2, 1, availableWidth),
            Math.Clamp((int)Math.Ceiling(size.Height) + 2, 1, availableHeight));
    }
}
