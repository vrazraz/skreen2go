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

namespace Skreen2Go.Windows;

public partial class EditorWindow : Window
{
    private readonly Bitmap source;
    private readonly AnnotationSession session = new();
    private AnnotationKind tool = AnnotationKind.Arrow;
    private PointI? dragStart;
    private PointI? dragEnd;
    private const uint Red = 0xFFFF4B66;

    public EditorWindow(Bitmap source)
    {
        this.source = source;
        InitializeComponent();
        ScreenshotImage.Source = ImageOutput.Preview(source);
        ImageSurface.Width = source.Width;
        ImageSurface.Height = source.Height;
        DrawingCanvas.Width = source.Width;
        DrawingCanvas.Height = source.Height;
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
        var point = ImagePoint(e.GetPosition(DrawingCanvas));
        if (tool == AnnotationKind.Text)
        {
            var prompt = new TextPrompt { Owner = this };
            if (prompt.ShowDialog() == true)
            {
                session.Add(new Annotation(AnnotationKind.Text, default, default,
                    new RectangleI(point.X, point.Y, 0, 0), prompt.Value, Red, 4, 1));
                DrawAnnotations();
            }
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
        dragStart = null;
        dragEnd = null;
        if (annotation is not null) session.Add(annotation);
        DrawAnnotations();
    }

    private Annotation? CurrentDrag()
    {
        if (dragStart is null || dragEnd is null) return null;
        var rect = SelectionGeometry.Normalize(dragStart.Value, dragEnd.Value);
        return new Annotation(tool, dragStart.Value, dragEnd.Value, rect,
            "", Red, 3, 1);
    }

    private void DrawAnnotations()
    {
        DrawingCanvas.Children.Clear();
        foreach (var annotation in session.Annotations) Draw(annotation);
        var preview = CurrentDrag();
        if (preview is not null && AnnotationGeometry.IsMeaningful(preview)) Draw(preview);
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
                    FontSize = Math.Max(8, annotation.Thickness * 8),
                    FontFamily = new System.Windows.Media.FontFamily("Segoe UI")
                };
                Canvas.SetLeft(text, annotation.Rect.X);
                Canvas.SetTop(text, annotation.Rect.Y);
                DrawingCanvas.Children.Add(text);
                break;
        }
    }

    private void SetTool(AnnotationKind kind)
    {
        tool = kind;
        StatusText.Text = $"{kind} · drag to draw · Ctrl+C to copy · Ctrl+S to save";
    }

    private void OnArrow(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Arrow);
    private void OnRectangle(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Rectangle);
    private void OnText(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Text);
    private void OnUndo(object sender, RoutedEventArgs e) { session.Undo(); DrawAnnotations(); }
    private void OnRedo(object sender, RoutedEventArgs e) { session.Redo(); DrawAnnotations(); }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        try
        {
            using var rendered = ImageOutput.Render(source, session.Annotations);
            ImageOutput.Copy(rendered);
            Close();
        }
        catch (Exception error) { ShowError("Cannot copy the screenshot", error); }
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var folder = System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        SaveTo(OutputNaming.NextPath(folder, "Screenshot", DateTimeOffset.Now, System.IO.File.Exists));
    }

    private void OnSaveAs(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Save screenshot",
            Filter = "PNG image|*.png|JPEG image|*.jpg",
            FileName = System.IO.Path.GetFileName(OutputNaming.NextPath(".", "Screenshot",
                DateTimeOffset.Now, _ => false)),
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
        catch (Exception error) { ShowError("Cannot save the screenshot", error); }
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();

    private void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape) Close();
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.Z)
        { session.Undo(); DrawAnnotations(); e.Handled = true; }
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.Y)
        { session.Redo(); DrawAnnotations(); e.Handled = true; }
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.C)
        { OnCopy(this, new RoutedEventArgs()); e.Handled = true; }
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.S)
        { OnSave(this, new RoutedEventArgs()); e.Handled = true; }
    }

    private void ShowError(string operation, Exception error) =>
        MessageBox.Show(this, $"{operation}: {error.Message}", "Skreen2Go",
            MessageBoxButton.OK, MessageBoxImage.Error);
}
