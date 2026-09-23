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
    float Opacity);

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
}
