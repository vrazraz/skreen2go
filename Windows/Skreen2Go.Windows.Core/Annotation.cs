namespace Skreen2Go.Windows.Core;

public enum AnnotationKind { Arrow, Rectangle, Text, Blur, Cursor }

public sealed record Annotation(
    AnnotationKind Kind,
    PointI Start,
    PointI End,
    RectangleI Rect,
    string Text,
    uint Color,
    float Thickness,
    float Opacity,
    float FontSize = 24,
    int BlurRadius = 12);

public static class AnnotationGeometry
{
    public static bool IsMeaningful(Annotation annotation) => annotation.Kind switch
    {
        AnnotationKind.Arrow => Math.Sqrt(
            Math.Pow((double)annotation.End.X - annotation.Start.X, 2) +
            Math.Pow((double)annotation.End.Y - annotation.Start.Y, 2)) >= 6,
        AnnotationKind.Rectangle or AnnotationKind.Blur =>
            annotation.Rect.Width >= 4 && annotation.Rect.Height >= 4,
        AnnotationKind.Text => !string.IsNullOrWhiteSpace(annotation.Text),
        AnnotationKind.Cursor => !annotation.Rect.IsEmpty,
        _ => false
    };

    public static Annotation Move(Annotation annotation, int dx, int dy, RectangleI bounds)
    {
        if (annotation.Kind == AnnotationKind.Arrow)
        {
            var minX = Math.Min(annotation.Start.X, annotation.End.X);
            var maxX = Math.Max(annotation.Start.X, annotation.End.X);
            var minY = Math.Min(annotation.Start.Y, annotation.End.Y);
            var maxY = Math.Max(annotation.Start.Y, annotation.End.Y);
            dx = Math.Clamp(dx, bounds.X - minX, bounds.Right - maxX);
            dy = Math.Clamp(dy, bounds.Y - minY, bounds.Bottom - maxY);
            return annotation with
            {
                Start = new PointI(annotation.Start.X + dx, annotation.Start.Y + dy),
                End = new PointI(annotation.End.X + dx, annotation.End.Y + dy)
            };
        }
        var rect = annotation.Rect;
        var x = Math.Clamp(rect.X + dx, bounds.X,
            Math.Max(bounds.X, bounds.Right - rect.Width));
        var y = Math.Clamp(rect.Y + dy, bounds.Y,
            Math.Max(bounds.Y, bounds.Bottom - rect.Height));
        return annotation with { Rect = rect with { X = x, Y = y } };
    }

    public static bool Contains(Annotation annotation, PointI point)
    {
        if (annotation.Kind == AnnotationKind.Arrow)
        {
            var x = annotation.Start.X;
            var y = annotation.Start.Y;
            var vx = annotation.End.X - x;
            var vy = annotation.End.Y - y;
            var lengthSquared = (double)vx * vx + (double)vy * vy;
            if (lengthSquared == 0) return false;
            var t = Math.Clamp(((point.X - x) * (double)vx +
                (point.Y - y) * (double)vy) / lengthSquared, 0, 1);
            var distance = Math.Sqrt(Math.Pow(point.X - (x + t * vx), 2) +
                Math.Pow(point.Y - (y + t * vy), 2));
            return distance <= Math.Max(6, annotation.Thickness + 3);
        }
        var rect = annotation.Rect;
        if (annotation.Kind == AnnotationKind.Text)
            rect = rect with
            {
                Width = (int)Math.Ceiling(annotation.Text.Length * annotation.FontSize * .6),
                Height = (int)Math.Ceiling(annotation.FontSize * 1.5)
            };
        return point.X >= rect.X && point.X < rect.Right &&
               point.Y >= rect.Y && point.Y < rect.Bottom;
    }
}
