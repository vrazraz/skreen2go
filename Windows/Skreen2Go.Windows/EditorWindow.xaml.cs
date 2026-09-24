using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Microsoft.Win32;
using Skreen2Go.Windows.Core;
using MessageBox = System.Windows.MessageBox;
using WpfPoint = System.Windows.Point;
using WpfRectangle = System.Windows.Shapes.Rectangle;
using TextBox = System.Windows.Controls.TextBox;

namespace Skreen2Go.Windows;

public partial class EditorWindow : Window
{
    private readonly Bitmap source;
    private readonly AppSettings settings;
    private readonly AnnotationSession session = new();
    private AnnotationKind? tool = AnnotationKind.Arrow;
    private int? selectedIndex;
    private PointI? dragStart;
    private PointI? dragEnd;
    private InlineTextEntry? textEntry;
    private bool draggingExistingText;

    public EditorWindow(Bitmap source, AppSettings settings,
        IEnumerable<Annotation>? initialAnnotations = null)
    {
        this.source = source;
        this.settings = settings;
        InitializeComponent();
        if (initialAnnotations is not null)
            foreach (var annotation in initialAnnotations) session.Add(annotation);
        ScreenshotImage.Source = ImageOutput.Preview(source);
        ImageSurface.Width = source.Width;
        ImageSurface.Height = source.Height;
        DrawingCanvas.Width = source.Width;
        DrawingCanvas.Height = source.Height;
        DrawAnnotations();
        var workArea = SystemParameters.WorkArea;
        var scale = Math.Min(1, Math.Min((workArea.Width - 120) / source.Width,
            (workArea.Height - 190) / source.Height));
        PreviewBox.Width = Math.Max(1, source.Width * scale);
        PreviewBox.Height = Math.Max(1, source.Height * scale);
        Closed += (_, _) => source.Dispose();
    }

    private PointI ImagePoint(WpfPoint point) => new(
        Math.Clamp((int)Math.Round(point.X), 0, source.Width - 1),
        Math.Clamp((int)Math.Round(point.Y), 0, source.Height - 1));

    private void OnCanvasMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (textEntry is not null) return;
        var point = ImagePoint(e.GetPosition(DrawingCanvas));
        for (var index = session.Annotations.Count - 1; index >= 0; index--)
        {
            var existing = session.Annotations[index];
            if (existing.Kind != AnnotationKind.Text ||
                !AnnotationGeometry.Contains(existing, point)) continue;
            selectedIndex = index;
            draggingExistingText = true;
            dragStart = point;
            dragEnd = point;
            DrawingCanvas.CaptureMouse();
            DrawAnnotations();
            return;
        }
        if (tool is null)
        {
            selectedIndex = session.HitTest(point);
            dragStart = selectedIndex is null ? null : point;
            dragEnd = dragStart;
            if (selectedIndex is not null) DrawingCanvas.CaptureMouse();
            DrawAnnotations();
            return;
        }
        if (tool == AnnotationKind.Text)
        {
            if (textEntry is not null) return;
            selectedIndex = null;
            point = new PointI(Math.Min(point.X, Math.Max(0, source.Width - 80)),
                Math.Min(point.Y, Math.Max(0, source.Height - 36)));
            textEntry = InlineTextEntry.Show(DrawingCanvas,
                new WpfPoint(point.X, point.Y), settings.TextSize,
                new SolidColorBrush(System.Windows.Media.Color.FromArgb(
                    (byte)(settings.AnnotationColor >> 24),
                    (byte)(settings.AnnotationColor >> 16),
                    (byte)(settings.AnnotationColor >> 8),
                    (byte)settings.AnnotationColor)),
                Math.Min(340, source.Width - point.X - 8),
                value =>
                {
                    var rect = TextAnnotationLayout.Measure(value, point, settings.TextSize,
                        new RectangleI(0, 0, source.Width, source.Height));
                    session.Add(new Annotation(AnnotationKind.Text, default, default,
                        rect, value,
                        settings.AnnotationColor, settings.AnnotationThickness, 1,
                        settings.TextSize));
                    DrawAnnotations();
                },
                () => textEntry = null);
            return;
        }
        if (tool == AnnotationKind.Cursor)
        {
            session.Add(new Annotation(AnnotationKind.Cursor, default, default,
                new RectangleI(point.X - 12, point.Y - 12, 24, 24), "",
                settings.AnnotationColor, settings.AnnotationThickness, 1));
            DrawAnnotations();
            return;
        }
        dragStart = point;
        dragEnd = point;
        DrawingCanvas.CaptureMouse();
    }

    private void OnCanvasMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (dragStart is null) return;
        dragEnd = ImagePoint(e.GetPosition(DrawingCanvas));
        DrawAnnotations();
    }

    private void OnCanvasMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (dragStart is null) return;
        dragEnd = ImagePoint(e.GetPosition(DrawingCanvas));
        DrawingCanvas.ReleaseMouseCapture();
        var annotation = CurrentDrag();
        var clickedText = draggingExistingText && selectedIndex is { } index &&
            Math.Abs(dragEnd.Value.X - dragStart.Value.X) < 4 &&
            Math.Abs(dragEnd.Value.Y - dragStart.Value.Y) < 4;
        var clickedPoint = dragEnd.Value;
        dragStart = null;
        dragEnd = null;
        draggingExistingText = false;
        if (annotation is not null)
        {
            if (clickedText) { DrawAnnotations(); EditText(selectedIndex!.Value, clickedPoint); return; }
            if ((tool is null || annotation.Kind == AnnotationKind.Text) && selectedIndex is not null)
                session.ReplaceAt(selectedIndex.Value, annotation);
            else session.Add(annotation);
        }
        DrawAnnotations();
    }

    private void EditText(int index, PointI clickedAt)
    {
        if (textEntry is not null || index >= session.Annotations.Count) return;
        var annotation = session.Annotations[index];
        var origin = new WpfPoint(annotation.Rect.X, annotation.Rect.Y);
        var color = System.Windows.Media.Color.FromArgb(
            (byte)(annotation.Color >> 24), (byte)(annotation.Color >> 16),
            (byte)(annotation.Color >> 8), (byte)annotation.Color);
        textEntry = InlineTextEntry.Show(DrawingCanvas, origin,
            annotation.FontSize, new SolidColorBrush(color),
            Math.Min(340, source.Width - annotation.Rect.X),
            value =>
            {
                var rect = TextAnnotationLayout.Measure(value,
                    new PointI(annotation.Rect.X, annotation.Rect.Y),
                    annotation.FontSize,
                    new RectangleI(0, 0, source.Width, source.Height));
                session.ReplaceAt(index, annotation with { Text = value, Rect = rect });
                DrawAnnotations();
            },
            () => textEntry = null, annotation.Text,
            new WpfPoint(clickedAt.X - origin.X, clickedAt.Y - origin.Y));
    }

    private void OnPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (textEntry is null || e.OriginalSource is not DependencyObject source ||
            textEntry.Contains(source)) return;
        textEntry.Commit();
        if (!IsInside(source, DrawingCanvas)) return;
        e.Handled = true;
    }

    private static bool IsInside(DependencyObject source, DependencyObject target)
    {
        for (DependencyObject? current = source; current is not null;
            current = VisualTreeHelper.GetParent(current))
            if (ReferenceEquals(current, target)) return true;
        return false;
    }

    private Annotation? CurrentDrag()
    {
        if (dragStart is null || dragEnd is null) return null;
        if (tool is null || draggingExistingText)
        {
            if (selectedIndex is null) return null;
            return AnnotationGeometry.Move(session.Annotations[selectedIndex.Value],
                dragEnd.Value.X - dragStart.Value.X,
                dragEnd.Value.Y - dragStart.Value.Y,
                new RectangleI(0, 0, source.Width, source.Height));
        }
        var rect = SelectionGeometry.Normalize(dragStart.Value, dragEnd.Value);
        return new Annotation(tool.Value, dragStart.Value, dragEnd.Value, rect,
            "", settings.AnnotationColor, settings.AnnotationThickness, 1,
            BlurRadius: settings.BlurRadius);
    }

    private void DrawAnnotations()
    {
        DrawingCanvas.Children.Clear();
        for (var index = 0; index < session.Annotations.Count; index++)
        {
            if (index == selectedIndex && dragStart is not null) continue;
            Draw(session.Annotations[index]);
        }
        var preview = CurrentDrag();
        if (preview is not null && AnnotationGeometry.IsMeaningful(preview)) Draw(preview);
        if (selectedIndex is not null && selectedIndex.Value < session.Annotations.Count)
            DrawSelectionOutline(preview ?? session.Annotations[selectedIndex.Value]);
    }

    private void DrawSelectionOutline(Annotation annotation)
    {
        var rect = annotation.Kind == AnnotationKind.Arrow
            ? SelectionGeometry.Normalize(annotation.Start, annotation.End)
            : annotation.Rect;
        if (annotation.Kind == AnnotationKind.Text && rect.IsEmpty)
            rect = rect with
            {
                Width = (int)Math.Ceiling(annotation.Text.Length * annotation.FontSize * .6),
                Height = (int)Math.Ceiling(annotation.FontSize * 1.5)
            };
        var outline = new WpfRectangle
        {
            Width = Math.Max(4, rect.Width + 8),
            Height = Math.Max(4, rect.Height + 8),
            Stroke = System.Windows.Media.Brushes.DeepSkyBlue,
            StrokeThickness = 1,
            StrokeDashArray = [4, 3]
        };
        Canvas.SetLeft(outline, rect.X - 4);
        Canvas.SetTop(outline, rect.Y - 4);
        DrawingCanvas.Children.Add(outline);
    }

    private void Draw(Annotation annotation)
    {
        var color = System.Windows.Media.Color.FromArgb(
            (byte)(annotation.Color >> 24), (byte)(annotation.Color >> 16),
            (byte)(annotation.Color >> 8), (byte)annotation.Color);
        var brush = new SolidColorBrush(color);
        switch (annotation.Kind)
        {
            case AnnotationKind.Arrow:
                var line = new Line
                {
                    X1 = annotation.Start.X, Y1 = annotation.Start.Y,
                    X2 = annotation.End.X, Y2 = annotation.End.Y,
                    Stroke = brush, StrokeThickness = annotation.Thickness,
                    StrokeStartLineCap = PenLineCap.Round
                };
                DrawingCanvas.Children.Add(line);
                var angle = Math.Atan2(annotation.End.Y - annotation.Start.Y,
                    annotation.End.X - annotation.Start.X);
                var head = new Polygon { Fill = brush, Points = new PointCollection
                {
                    new(annotation.End.X, annotation.End.Y),
                    new(annotation.End.X - 15 * Math.Cos(angle - .45),
                        annotation.End.Y - 15 * Math.Sin(angle - .45)),
                    new(annotation.End.X - 15 * Math.Cos(angle + .45),
                        annotation.End.Y - 15 * Math.Sin(angle + .45))
                }};
                DrawingCanvas.Children.Add(head);
                break;
            case AnnotationKind.Rectangle:
                var rectangle = new WpfRectangle
                {
                    Width = annotation.Rect.Width,
                    Height = annotation.Rect.Height,
                    Stroke = brush,
                    StrokeThickness = annotation.Thickness
                };
                Canvas.SetLeft(rectangle, annotation.Rect.X);
                Canvas.SetTop(rectangle, annotation.Rect.Y);
                DrawingCanvas.Children.Add(rectangle);
                break;
            case AnnotationKind.Text:
                var text = new TextBlock
                {
                    Text = annotation.Text,
                    Foreground = brush,
                    FontSize = annotation.FontSize,
                    FontFamily = new System.Windows.Media.FontFamily("Segoe UI"),
                    TextWrapping = TextWrapping.Wrap,
                    MaxWidth = Math.Max(1, annotation.Rect.Width > 0
                        ? annotation.Rect.Width : source.Width - annotation.Rect.X)
                };
                Canvas.SetLeft(text, annotation.Rect.X);
                Canvas.SetTop(text, annotation.Rect.Y);
                DrawingCanvas.Children.Add(text);
                break;
            case AnnotationKind.Blur:
                var blur = new WpfRectangle
                {
                    Width = annotation.Rect.Width,
                    Height = annotation.Rect.Height,
                    Fill = new SolidColorBrush(System.Windows.Media.Color.FromArgb(80, 80, 80, 80)),
                    Stroke = brush,
                    StrokeThickness = 2,
                    StrokeDashArray = [4, 3]
                };
                Canvas.SetLeft(blur, annotation.Rect.X);
                Canvas.SetTop(blur, annotation.Rect.Y);
                DrawingCanvas.Children.Add(blur);
                break;
            case AnnotationKind.Cursor:
                var circle = new Ellipse
                {
                    Width = annotation.Rect.Width,
                    Height = annotation.Rect.Height,
                    Stroke = brush,
                    StrokeThickness = annotation.Thickness
                };
                Canvas.SetLeft(circle, annotation.Rect.X);
                Canvas.SetTop(circle, annotation.Rect.Y);
                DrawingCanvas.Children.Add(circle);
                break;
        }
    }

    private void SetTool(AnnotationKind? kind)
    {
        tool = kind;
        selectedIndex = null;
        StatusText.SetResourceReference(TextBlock.TextProperty,
            kind is null ? "EditorSelectHint" : "EditorDrawHint");
        DrawAnnotations();
    }

    private void OnSelect(object sender, RoutedEventArgs e) => SetTool(null);
    private void OnArrow(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Arrow);
    private void OnRectangle(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Rectangle);
    private void OnText(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Text);
    private void OnBlur(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Blur);
    private void OnCursor(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Cursor);
    private void OnUndo(object sender, RoutedEventArgs e)
    { session.Undo(); selectedIndex = null; DrawAnnotations(); }
    private void OnRedo(object sender, RoutedEventArgs e)
    { session.Redo(); selectedIndex = null; DrawAnnotations(); }
    private void OnClear(object sender, RoutedEventArgs e)
    {
        session.Clear();
        selectedIndex = null;
        DrawAnnotations();
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        try
        {
            using var rendered = ImageOutput.Render(source, session.Annotations);
            ImageOutput.Copy(rendered);
            var preview = ImageOutput.Preview(rendered);
            var topLeft = ImageSurface.PointToScreen(new WpfPoint(0, 0));
            var bottomRight = ImageSurface.PointToScreen(
                new WpfPoint(ImageSurface.ActualWidth, ImageSurface.ActualHeight));
            var area = new RectangleI((int)topLeft.X, (int)topLeft.Y,
                Math.Max(1, (int)(bottomRight.X - topLeft.X)),
                Math.Max(1, (int)(bottomRight.Y - topLeft.Y)));
            Close();
            Dispatcher.BeginInvoke(() => CaptureFeedback.Play(preview, area));
        }
        catch (Exception error) { ShowError("ErrorCopy", error); }
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        try
        {
            var extension = settings.ScreenshotFormat == ScreenshotFormat.Jpeg ? ".jpg" : ".png";
            SaveTo(OutputNaming.NextPath(settings.OutputFolder, "Screenshot", DateTimeOffset.Now,
                System.IO.File.Exists, extension));
        }
        catch (Exception error) { ShowError("ErrorSave", error); }
    }

    private void OnSaveAs(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = Localizer.Get("SaveScreenshot"),
            Filter = "PNG image|*.png|JPEG image|*.jpg",
            FileName = System.IO.Path.GetFileName(OutputNaming.NextPath(".", "Screenshot",
                DateTimeOffset.Now, _ => false,
                settings.ScreenshotFormat == ScreenshotFormat.Jpeg ? ".jpg" : ".png")),
            OverwritePrompt = true
        };
        if (dialog.ShowDialog(this) == true) SaveTo(dialog.FileName, overwrite: true);
    }

    private void SaveTo(string path, bool overwrite = false)
    {
        try
        {
            using var rendered = ImageOutput.Render(source, session.Annotations);
            ImageOutput.Save(rendered, path, overwrite);
            Close();
        }
        catch (Exception error) { ShowError("ErrorSave", error); }
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();

    private void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (textEntry is not null) return;
        if (e.Key == Key.Escape) Close();
        else if (selectedIndex is not null && e.Key is Key.Delete or Key.Back)
        {
            session.RemoveAt(selectedIndex.Value);
            selectedIndex = null;
            DrawAnnotations();
            e.Handled = true;
        }
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.Z)
        { OnUndo(this, new RoutedEventArgs()); e.Handled = true; }
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.Y)
        { OnRedo(this, new RoutedEventArgs()); e.Handled = true; }
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.C)
        { OnCopy(this, new RoutedEventArgs()); e.Handled = true; }
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.S)
        { OnSave(this, new RoutedEventArgs()); e.Handled = true; }
    }

    private void ShowError(string operation, Exception error) =>
        MessageBox.Show(this, $"{Localizer.Get(operation)}: {error.Message}", "Skreen2Go",
            MessageBoxButton.OK, MessageBoxImage.Error);
}
