using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;
using Skreen2Go.Windows.Core;

namespace Skreen2Go.Windows;

internal sealed class DesktopCapture : IDisposable
{
    public RectangleI Bounds { get; }
    public Bitmap Bitmap { get; }

    private DesktopCapture(RectangleI bounds, Bitmap bitmap)
    {
        Bounds = bounds;
        Bitmap = bitmap;
    }

    public static DesktopCapture Snapshot()
    {
        var virtualScreen = SystemInformation.VirtualScreen;
        var bounds = new RectangleI(virtualScreen.X, virtualScreen.Y,
            virtualScreen.Width, virtualScreen.Height);
        var bitmap = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        try
        {
            using var graphics = Graphics.FromImage(bitmap);
            graphics.CopyFromScreen(bounds.X, bounds.Y, 0, 0,
                new Size(bounds.Width, bounds.Height), CopyPixelOperation.SourceCopy);
            return new DesktopCapture(bounds, bitmap);
        }
        catch { bitmap.Dispose(); throw; }
    }

    public Bitmap Crop(RectangleI selection)
    {
        var local = SelectionGeometry.ToBitmapLocal(selection, Bounds);
        if (local.IsEmpty) throw new ArgumentException("The selected area is empty.", nameof(selection));
        return Bitmap.Clone(new Rectangle(local.X, local.Y, local.Width, local.Height),
            PixelFormat.Format32bppArgb);
    }

    public void Dispose() => Bitmap.Dispose();
}
