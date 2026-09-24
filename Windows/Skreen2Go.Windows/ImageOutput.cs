using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using Skreen2Go.Windows.Core;

namespace Skreen2Go.Windows;

public static class ImageOutput
{
    public static Bitmap Render(Bitmap source, IReadOnlyList<Annotation> annotations)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(annotations);
        var result = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
        try
        {
            using (var graphics = Graphics.FromImage(result))
                graphics.DrawImageUnscaled(source, 0, 0);
            foreach (var annotation in annotations)
            {
                if (annotation.Kind == AnnotationKind.Blur)
                    Blur(result, annotation.Rect, annotation.BlurRadius);
                else
                {
                    using var graphics = Graphics.FromImage(result);
                    graphics.SmoothingMode = SmoothingMode.AntiAlias;
                    graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
                    Draw(graphics, annotation);
                }
            }
            return result;
        }
        catch { result.Dispose(); throw; }
    }

    public static void Save(Bitmap image, string path, bool overwrite = false)
    {
        ArgumentNullException.ThrowIfNull(image);
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var folder = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(folder);
        var temp = Path.Combine(folder, $".{Guid.NewGuid():N}.tmp");
        try
        {
            image.Save(temp, Path.GetExtension(path).Equals(".jpg", StringComparison.OrdinalIgnoreCase) ||
                Path.GetExtension(path).Equals(".jpeg", StringComparison.OrdinalIgnoreCase)
                ? ImageFormat.Jpeg : ImageFormat.Png);
            File.Move(temp, path, overwrite);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    public static void Copy(Bitmap image)
    {
        using var stream = new MemoryStream();
        image.Save(stream, ImageFormat.Png);
        stream.Position = 0;
        var decoder = new PngBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
        var frame = decoder.Frames[0];
        frame.Freeze();
        System.Windows.Clipboard.SetImage(frame);
    }

    public static BitmapSource Preview(Bitmap image)
    {
        using var stream = new MemoryStream();
        image.Save(stream, ImageFormat.Png);
        stream.Position = 0;
        var decoder = new PngBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
        var frame = decoder.Frames[0];
        frame.Freeze();
        return frame;
    }

    private static void Draw(Graphics graphics, Annotation annotation)
    {
        var color = Color.FromArgb((int)annotation.Color);
        color = Color.FromArgb((int)(Math.Clamp(annotation.Opacity, 0, 1) * color.A), color);
        using var pen = new Pen(color, Math.Max(1, annotation.Thickness));
        pen.LineJoin = LineJoin.Round;
        switch (annotation.Kind)
        {
            case AnnotationKind.Arrow:
                pen.CustomEndCap = new AdjustableArrowCap(5, 6, true);
                graphics.DrawLine(pen, annotation.Start.X, annotation.Start.Y,
                    annotation.End.X, annotation.End.Y);
                break;
            case AnnotationKind.Rectangle:
                graphics.DrawRectangle(pen, annotation.Rect.X, annotation.Rect.Y,
                    annotation.Rect.Width, annotation.Rect.Height);
                break;
            case AnnotationKind.Text:
                using (var brush = new SolidBrush(color))
                using (var font = new Font("Segoe UI", Math.Max(8, annotation.FontSize),
                    System.Drawing.FontStyle.Regular, GraphicsUnit.Pixel))
                    graphics.DrawString(annotation.Text, font, brush,
                        new RectangleF(annotation.Rect.X, annotation.Rect.Y,
                            annotation.Rect.Width > 0 ? annotation.Rect.Width : 10000,
                            annotation.Rect.Height > 0 ? annotation.Rect.Height : 10000),
                        StringFormat.GenericTypographic);
                break;
            case AnnotationKind.Blur:
                break;
            case AnnotationKind.Cursor:
                graphics.DrawEllipse(pen, annotation.Rect.X, annotation.Rect.Y,
                    annotation.Rect.Width, annotation.Rect.Height);
                var centerX = annotation.Rect.X + annotation.Rect.Width / 2f;
                var centerY = annotation.Rect.Y + annotation.Rect.Height / 2f;
                graphics.DrawLine(pen, centerX - 5, centerY, centerX + 5, centerY);
                graphics.DrawLine(pen, centerX, centerY - 5, centerX, centerY + 5);
                break;
        }
    }

    private static void Blur(Bitmap bitmap, RectangleI area, int radius)
    {
        var clipped = SelectionGeometry.Clamp(area,
            new RectangleI(0, 0, bitmap.Width, bitmap.Height));
        if (clipped.IsEmpty) return;
        var width = clipped.Width;
        var height = clipped.Height;
        radius = Math.Clamp(radius, 1, 40);
        var rect = new Rectangle(clipped.X, clipped.Y, width, height);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            var source = new byte[width * height * 4];
            var horizontal = new byte[source.Length];
            var blurred = new byte[source.Length];
            for (var y = 0; y < height; y++)
                Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), source,
                    y * width * 4, width * 4);

            for (var y = 0; y < height; y++)
            for (var channel = 0; channel < 3; channel++)
            {
                var sum = 0;
                for (var x = 0; x <= Math.Min(radius, width - 1); x++)
                    sum += source[(y * width + x) * 4 + channel];
                for (var x = 0; x < width; x++)
                {
                    var count = Math.Min(width - 1, x + radius) -
                        Math.Max(0, x - radius) + 1;
                    horizontal[(y * width + x) * 4 + channel] = (byte)(sum / count);
                    if (x - radius >= 0)
                        sum -= source[(y * width + x - radius) * 4 + channel];
                    if (x + radius + 1 < width)
                        sum += source[(y * width + x + radius + 1) * 4 + channel];
                }
            }

            for (var x = 0; x < width; x++)
            for (var channel = 0; channel < 3; channel++)
            {
                var sum = 0;
                for (var y = 0; y <= Math.Min(radius, height - 1); y++)
                    sum += horizontal[(y * width + x) * 4 + channel];
                for (var y = 0; y < height; y++)
                {
                    var count = Math.Min(height - 1, y + radius) -
                        Math.Max(0, y - radius) + 1;
                    blurred[(y * width + x) * 4 + channel] = (byte)(sum / count);
                    if (y - radius >= 0)
                        sum -= horizontal[((y - radius) * width + x) * 4 + channel];
                    if (y + radius + 1 < height)
                        sum += horizontal[((y + radius + 1) * width + x) * 4 + channel];
                }
            }

            for (var i = 3; i < blurred.Length; i += 4) blurred[i] = source[i];
            for (var y = 0; y < height; y++)
                Marshal.Copy(blurred, y * width * 4,
                    IntPtr.Add(data.Scan0, y * data.Stride), width * 4);
        }
        finally { bitmap.UnlockBits(data); }
    }
}
