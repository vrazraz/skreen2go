using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
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
            using var graphics = Graphics.FromImage(result);
            graphics.DrawImageUnscaled(source, 0, 0);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
            foreach (var annotation in annotations)
                Draw(graphics, annotation);
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
                using (var font = new Font("Segoe UI", Math.Max(8, annotation.FontSize)))
                    graphics.DrawString(annotation.Text, font, brush,
                        annotation.Rect.X, annotation.Rect.Y);
                break;
            case AnnotationKind.Blur:
            case AnnotationKind.Cursor:
                break;
        }
    }
}
