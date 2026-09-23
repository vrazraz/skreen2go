using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Microsoft.Win32;
using Skreen2Go.Windows.Core;
using Bitmap = System.Drawing.Bitmap;
using Brushes = System.Windows.Media.Brushes;
using Button = System.Windows.Controls.Button;
using Cursors = System.Windows.Input.Cursors;
using FontFamily = System.Windows.Media.FontFamily;
using MessageBox = System.Windows.MessageBox;
using Path = System.IO.Path;
using SaveFileDialog = Microsoft.Win32.SaveFileDialog;
using Size = System.Windows.Size;
using WpfPoint = System.Windows.Point;
using WpfRectangle = System.Windows.Shapes.Rectangle;

namespace Skreen2Go.Windows;

public partial class CaptureWindow : Window
{
    private enum Gesture { None, Creating, Moving, Resizing, Drawing }

    private static readonly uint[] PaletteColors =
    [
        0xFFFF453A, 0xFFFF9F0A, 0xFFFFD60A, 0xFF30D158, 0xFF64D2FF,
        0xFF0A84FF, 0xFFBF5AF2, 0xFFFF375F, 0xFFFFFFFF, 0xFF111111
    ];

    private readonly DesktopCapture capture;
    private readonly bool recordingMode;
    private AnnotationSession annotations = new();
    private AppSettings settings;
    private uint currentColor;
    private bool recordSystemAudio;
    private bool recordMicrophone;
    private RectangleI? selection;
    private RectangleI gestureFrame;
    private PointI gestureAnchor;
    private PointI gestureCurrent;
    private SelectionHandle? resizeHandle;
    private Gesture gesture;
    private AnnotationKind? tool;
    private Annotation? draft;

    public event Action<RectangleI, IReadOnlyList<Annotation>>? CaptureAccepted;
    public event Action<RectangleI, bool, bool>? RecordingAccepted;
    public event Action? SettingsRequested;

    internal CaptureWindow(DesktopCapture capture, AppSettings settings, bool recording = false)
    {
        this.capture = capture;
        this.settings = settings;
        recordingMode = recording;
        currentColor = settings.AnnotationColor;
        recordSystemAudio = settings.RecordSystemAudio;
        recordMicrophone = settings.RecordMicrophone;
        InitializeComponent();
        if (recording)
        {
            Instruction.SetResourceReference(TextBlock.TextProperty, "RecordingHint");
            ScreenshotControls.Visibility = Visibility.Collapsed;
            RecordingControls.Visibility = Visibility.Visible;
        }
        var source = BitmapSourceFromBitmap(capture.Bitmap);
        DimmedImage.Source = source;
        SelectedImage.Source = source;
        BuildPalette();
        UpdateButtonStates();
        Loaded += (_, _) => { Activate(); Focus(); };
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            NativeMethods.SetWindowPos(handle, IntPtr.Zero, capture.Bounds.X, capture.Bounds.Y,
                capture.Bounds.Width, capture.Bounds.Height, 0x0040);
        };
    }

    public void ApplySettings(AppSettings current)
    {
        settings = current;
        currentColor = current.AnnotationColor;
        recordSystemAudio = current.RecordSystemAudio;
        recordMicrophone = current.RecordMicrophone;
        UpdateButtonStates();
    }

    private static BitmapSource BitmapSourceFromBitmap(Bitmap bitmap)
    {
        using var stream = new MemoryStream();
        bitmap.Save(stream, System.Drawing.Imaging.ImageFormat.Png);
        stream.Position = 0;
        var decoder = new PngBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
        var source = decoder.Frames[0];
        source.Freeze();
        return source;
    }

    private PointI CursorPoint()
    {
        if (!NativeMethods.GetCursorPos(out var cursor)) return gestureCurrent;
        return new PointI(cursor.X, cursor.Y);
    }

    private static bool Contains(RectangleI rect, PointI point) =>
        point.X >= rect.X && point.X < rect.Right &&
        point.Y >= rect.Y && point.Y < rect.Bottom;

    private static PointI LocalPoint(RectangleI frame, PointI point) => new(
        Math.Clamp(point.X - frame.X, 0, frame.Width),
        Math.Clamp(point.Y - frame.Y, 0, frame.Height));

    private WpfPoint OnOverlay(PointI screenPoint) =>
        PointFromScreen(new WpfPoint(screenPoint.X, screenPoint.Y));

    private Rect OnOverlay(RectangleI screenRect)
    {
        var topLeft = OnOverlay(new PointI(screenRect.X, screenRect.Y));
        var bottomRight = OnOverlay(new PointI(screenRect.Right, screenRect.Bottom));
        return new Rect(topLeft, bottomRight);
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        var point = CursorPoint();
        if (selection is { } frame)
        {
            if (!recordingMode && tool is not null && Contains(frame, point))
            {
                if (tool == AnnotationKind.Text)
                {
                    AddText(LocalPoint(frame, point));
                    return;
                }
                gesture = Gesture.Drawing;
                gestureAnchor = point;
                gestureCurrent = point;
                HidePanel();
                CaptureMouse();
                return;
            }

            resizeHandle = LiveSelectionGeometry.HandleAt(frame, point);
            if (resizeHandle is not null)
            {
                gesture = Gesture.Resizing;
                gestureFrame = frame;
            }
            else if (Contains(frame, point))
            {
                if (!recordingMode && e.ClickCount >= 2) { OpenEditor(); return; }
                gesture = Gesture.Moving;
                gestureFrame = frame;
            }
            else
            {
                selection = null;
                annotations = new AnnotationSession();
                tool = null;
                gesture = Gesture.Creating;
            }
        }
        else gesture = Gesture.Creating;

        gestureAnchor = point;
        gestureCurrent = point;
        HidePanel();
        CaptureMouse();
        DrawSelection();
    }

    private void OnMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (gesture == Gesture.None)
        {
            UpdateCursor(CursorPoint());
            return;
        }
        gestureCurrent = CursorPoint();
        UpdateGesture();
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (gesture == Gesture.None) return;
        gestureCurrent = CursorPoint();
        UpdateGesture();
        ReleaseMouseCapture();
        if (gesture == Gesture.Creating &&
            (selection is null || selection.Value.Width < 8 || selection.Value.Height < 8))
            selection = capture.WindowAt(gestureAnchor);
        if (gesture == Gesture.Drawing && draft is not null)
            annotations.Add(draft);
        if (selection is { } frame && (frame.Width < 8 || frame.Height < 8))
            selection = null;
        draft = null;
        gesture = Gesture.None;
        DrawSelection();
        ShowPanel();
        UpdateCursor(gestureCurrent);
    }

    private void UpdateGesture()
    {
        switch (gesture)
        {
            case Gesture.Creating:
                selection = SelectionGeometry.Clamp(
                    SelectionGeometry.Normalize(gestureAnchor, gestureCurrent), capture.Bounds);
                break;
            case Gesture.Moving:
                selection = LiveSelectionGeometry.Move(gestureFrame,
                    gestureCurrent.X - gestureAnchor.X,
                    gestureCurrent.Y - gestureAnchor.Y, capture.Bounds);
                break;
            case Gesture.Resizing:
                selection = LiveSelectionGeometry.Resize(gestureFrame, resizeHandle!.Value,
                    gestureCurrent, capture.Bounds);
                break;
            case Gesture.Drawing:
                draft = DraftAnnotation();
                break;
        }
        DrawSelection();
    }

    private Annotation? DraftAnnotation()
    {
        if (selection is not { } frame || tool is null) return null;
        var start = LocalPoint(frame, gestureAnchor);
        var end = LocalPoint(frame, gestureCurrent);
        return new Annotation(tool.Value, start, end,
            SelectionGeometry.Normalize(start, end), "", currentColor,
            settings.AnnotationThickness, 1, settings.TextSize, settings.BlurRadius);
    }

    private void UpdateCursor(PointI point)
    {
        if (selection is not { } frame) { Cursor = Cursors.Cross; return; }
        if (!recordingMode && tool is not null && Contains(frame, point))
        { Cursor = Cursors.Cross; return; }
        Cursor = LiveSelectionGeometry.HandleAt(frame, point) switch
        {
            SelectionHandle.TopLeft or SelectionHandle.BottomRight => Cursors.SizeNWSE,
            SelectionHandle.TopRight or SelectionHandle.BottomLeft => Cursors.SizeNESW,
            SelectionHandle.Left or SelectionHandle.Right => Cursors.SizeWE,
            SelectionHandle.Top or SelectionHandle.Bottom => Cursors.SizeNS,
            _ => Contains(frame, point) ? Cursors.SizeAll : Cursors.Cross
        };
    }

    private void DrawSelection()
    {
        SelectionCanvas.Children.Clear();
        AnnotationCanvas.Children.Clear();
        if (selection is not { } frame || frame.IsEmpty)
        {
            SelectedImage.Clip = Geometry.Empty;
            AnnotationCanvas.Clip = Geometry.Empty;
            SizeBadge.Visibility = Visibility.Collapsed;
            InstructionPanel.Visibility = Visibility.Visible;
            return;
        }
        var box = OnOverlay(frame);
        SelectedImage.Clip = new RectangleGeometry(box);
        AnnotationCanvas.Clip = new RectangleGeometry(box);
        InstructionPanel.Visibility = Visibility.Collapsed;

        var border = new WpfRectangle
        {
            Width = box.Width, Height = box.Height,
            Stroke = Brushes.White, StrokeThickness = 2,
            Fill = Brushes.Transparent
        };
        Canvas.SetLeft(border, box.Left);
        Canvas.SetTop(border, box.Top);
        SelectionCanvas.Children.Add(border);

        var xs = new[] { box.Left, box.Left + box.Width / 2, box.Right };
        var ys = new[] { box.Top, box.Top + box.Height / 2, box.Bottom };
        foreach (var (x, y) in new[]
        {
            (xs[0], ys[0]), (xs[1], ys[0]), (xs[2], ys[0]),
            (xs[2], ys[1]), (xs[2], ys[2]), (xs[1], ys[2]),
            (xs[0], ys[2]), (xs[0], ys[1])
        })
        {
            var handle = new WpfRectangle
            {
                Width = 9, Height = 9, Fill = Brushes.White,
                Stroke = new SolidColorBrush(ColorFromArgb(0x99000000)),
                StrokeThickness = 1
            };
            Canvas.SetLeft(handle, x - 4.5);
            Canvas.SetTop(handle, y - 4.5);
            SelectionCanvas.Children.Add(handle);
        }

        SizeText.Text = $"{frame.Width} × {frame.Height}";
        SizeBadge.Visibility = Visibility.Visible;
        SizeBadge.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(SizeBadge, Math.Clamp(box.Left, 0,
            Math.Max(0, Root.ActualWidth - SizeBadge.DesiredSize.Width)));
        Canvas.SetTop(SizeBadge, box.Top >= 28 ? box.Top - 28 : box.Bottom + 7);
        foreach (var annotation in annotations.Annotations)
            DrawAnnotation(annotation, frame);
        if (draft is not null && AnnotationGeometry.IsMeaningful(draft))
            DrawAnnotation(draft, frame);
    }

    private static System.Windows.Media.Color ColorFromArgb(uint argb) =>
        System.Windows.Media.Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16),
            (byte)(argb >> 8), (byte)argb);

    private void DrawAnnotation(Annotation annotation, RectangleI frame)
    {
        WpfPoint Position(PointI local) => OnOverlay(new PointI(frame.X + local.X,
            frame.Y + local.Y));
        var brush = new SolidColorBrush(ColorFromArgb(annotation.Color));
        var stroke = Math.Max(1, annotation.Thickness);
        switch (annotation.Kind)
        {
            case AnnotationKind.Arrow:
                var start = Position(annotation.Start);
                var end = Position(annotation.End);
                AnnotationCanvas.Children.Add(new Line
                {
                    X1 = start.X, Y1 = start.Y, X2 = end.X, Y2 = end.Y,
                    Stroke = brush, StrokeThickness = stroke,
                    StrokeStartLineCap = PenLineCap.Round
                });
                var angle = Math.Atan2(end.Y - start.Y, end.X - start.X);
                AnnotationCanvas.Children.Add(new Polygon
                {
                    Fill = brush,
                    Points = new PointCollection
                    {
                        end,
                        new(end.X - 14 * Math.Cos(angle - .45),
                            end.Y - 14 * Math.Sin(angle - .45)),
                        new(end.X - 14 * Math.Cos(angle + .45),
                            end.Y - 14 * Math.Sin(angle + .45))
                    }
                });
                break;
            case AnnotationKind.Rectangle:
                var topLeft = Position(new PointI(annotation.Rect.X, annotation.Rect.Y));
                var bottomRight = Position(new PointI(annotation.Rect.Right, annotation.Rect.Bottom));
                var rectangle = new WpfRectangle
                {
                    Width = Math.Max(0, bottomRight.X - topLeft.X),
                    Height = Math.Max(0, bottomRight.Y - topLeft.Y),
                    Stroke = brush, StrokeThickness = stroke
                };
                Canvas.SetLeft(rectangle, topLeft.X);
                Canvas.SetTop(rectangle, topLeft.Y);
                AnnotationCanvas.Children.Add(rectangle);
                break;
            case AnnotationKind.Text:
                var origin = Position(new PointI(annotation.Rect.X, annotation.Rect.Y));
                var scaled = Position(new PointI(annotation.Rect.X,
                    annotation.Rect.Y + (int)Math.Ceiling(annotation.FontSize)));
                var text = new TextBlock
                {
                    Text = annotation.Text, Foreground = brush,
                    FontSize = Math.Max(8, scaled.Y - origin.Y),
                    FontFamily = new FontFamily("Segoe UI")
                };
                Canvas.SetLeft(text, origin.X);
                Canvas.SetTop(text, origin.Y);
                AnnotationCanvas.Children.Add(text);
                break;
        }
    }

    private void ShowPanel()
    {
        if (selection is not { } frame) return;
        ActionPanel.Visibility = Visibility.Visible;
        ActionPanel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var area = OnOverlay(frame);
        var bounds = new RectangleI(0, 0,
            (int)Math.Ceiling(Root.ActualWidth), (int)Math.Ceiling(Root.ActualHeight));
        var place = FloatingBarPlacement.Place(
            new RectangleI((int)area.X, (int)area.Y,
                (int)Math.Ceiling(area.Width), (int)Math.Ceiling(area.Height)),
            (int)Math.Ceiling(ActionPanel.DesiredSize.Width),
            (int)Math.Ceiling(ActionPanel.DesiredSize.Height), bounds);
        Canvas.SetLeft(ActionPanel, place.X);
        Canvas.SetTop(ActionPanel, place.Y);
        ActionPanel.UpdateLayout();
    }

    private void HidePanel()
    {
        ActionPanel.Visibility = Visibility.Collapsed;
        ColorPalette.Visibility = Visibility.Collapsed;
    }

    private void BuildPalette()
    {
        foreach (var color in PaletteColors)
        {
            var button = new Button
            {
                Width = 22, Height = 22, Margin = new Thickness(3),
                Background = new SolidColorBrush(ColorFromArgb(color)),
                BorderBrush = Brushes.Gray,
                BorderThickness = new Thickness(1),
                Tag = color,
                Cursor = Cursors.Hand
            };
            button.Click += (_, _) =>
            {
                currentColor = (uint)button.Tag;
                ColorPalette.Visibility = Visibility.Collapsed;
                UpdateButtonStates();
            };
            PaletteItems.Children.Add(button);
        }
    }

    private void UpdateButtonStates()
    {
        ColorButton.Background = new SolidColorBrush(ColorFromArgb(currentColor));
        ArrowButton.Background = tool == AnnotationKind.Arrow
            ? Brushes.DodgerBlue : new SolidColorBrush(ColorFromArgb(0xFFF2F4F5));
        RectangleButton.Background = tool == AnnotationKind.Rectangle
            ? Brushes.DodgerBlue : new SolidColorBrush(ColorFromArgb(0xFFF2F4F5));
        TextButton.Background = tool == AnnotationKind.Text
            ? Brushes.DodgerBlue : new SolidColorBrush(ColorFromArgb(0xFFF2F4F5));
        ArrowButton.Foreground = tool == AnnotationKind.Arrow ? Brushes.White : Brushes.Black;
        RectangleButton.Foreground = tool == AnnotationKind.Rectangle ? Brushes.White : Brushes.Black;
        TextButton.Foreground = tool == AnnotationKind.Text ? Brushes.White : Brushes.Black;
        SystemAudioButton.Background = recordSystemAudio
            ? Brushes.DodgerBlue : new SolidColorBrush(ColorFromArgb(0xFFF2F4F5));
        MicrophoneButton.Background = recordMicrophone
            ? Brushes.DodgerBlue : new SolidColorBrush(ColorFromArgb(0xFFF2F4F5));
        SystemAudioButton.Foreground = recordSystemAudio ? Brushes.White : Brushes.Black;
        MicrophoneButton.Foreground = recordMicrophone ? Brushes.White : Brushes.Black;
    }

    private void AddText(PointI point)
    {
        var prompt = new TextPrompt { Owner = this };
        if (prompt.ShowDialog() != true) return;
        annotations.Add(new Annotation(AnnotationKind.Text, default, default,
            new RectangleI(point.X, point.Y, 0, 0), prompt.Value,
            currentColor, settings.AnnotationThickness, 1, settings.TextSize));
        DrawSelection();
    }

    private void SetTool(AnnotationKind kind)
    {
        tool = tool == kind ? null : kind;
        ColorPalette.Visibility = Visibility.Collapsed;
        UpdateButtonStates();
    }

    private void OnArrow(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Arrow);
    private void OnRectangle(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Rectangle);
    private void OnText(object sender, RoutedEventArgs e) => SetTool(AnnotationKind.Text);
    private void OnUndo(object sender, RoutedEventArgs e)
    { annotations.Undo(); DrawSelection(); }
    private void OnRedo(object sender, RoutedEventArgs e)
    { annotations.Redo(); DrawSelection(); }

    private void OnColor(object sender, RoutedEventArgs e)
    {
        if (ColorPalette.Visibility == Visibility.Visible)
        { ColorPalette.Visibility = Visibility.Collapsed; return; }
        ColorPalette.Visibility = Visibility.Visible;
        var position = ColorButton.TransformToAncestor(HudCanvas)
            .Transform(new WpfPoint(0, ColorButton.ActualHeight));
        ColorPalette.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(ColorPalette, Math.Clamp(position.X,
            0, Math.Max(0, Root.ActualWidth - ColorPalette.DesiredSize.Width)));
        var below = Canvas.GetTop(ActionPanel) + ActionPanel.ActualHeight + 6;
        Canvas.SetTop(ColorPalette,
            below + ColorPalette.DesiredSize.Height <= Root.ActualHeight
                ? below : Math.Max(0, Canvas.GetTop(ActionPanel) -
                    ColorPalette.DesiredSize.Height - 6));
    }

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        Hide();
        try { SettingsRequested?.Invoke(); }
        finally { Show(); Topmost = true; Activate(); ShowPanel(); }
    }

    private void OnSystemAudio(object sender, RoutedEventArgs e)
    { recordSystemAudio = !recordSystemAudio; UpdateButtonStates(); }
    private void OnMicrophone(object sender, RoutedEventArgs e)
    { recordMicrophone = !recordMicrophone; UpdateButtonStates(); }

    private void OnRecord(object sender, RoutedEventArgs e)
    {
        if (selection is not { } frame) return;
        RecordingAccepted?.Invoke(frame, recordSystemAudio, recordMicrophone);
        Close();
    }

    private void OpenEditor()
    {
        if (selection is not { } frame || recordingMode) return;
        CaptureAccepted?.Invoke(frame, annotations.Annotations.ToArray());
        Close();
    }

    private Bitmap RenderSelection()
    {
        if (selection is not { } frame) throw new InvalidOperationException("No selection.");
        using var cropped = capture.Crop(frame);
        return ImageOutput.Render(cropped, annotations.Annotations);
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (selection is null) return;
        try
        {
            using var image = RenderSelection();
            ImageOutput.Copy(image);
            Close();
        }
        catch (Exception error) { ShowError("ErrorCopy", error); }
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (selection is null) return;
        try
        {
            var extension = settings.ScreenshotFormat == ScreenshotFormat.Jpeg ? ".jpg" : ".png";
            var path = OutputNaming.NextPath(settings.OutputFolder, "Screenshot",
                DateTimeOffset.Now, File.Exists, extension);
            using var image = RenderSelection();
            ImageOutput.Save(image, path);
            Close();
        }
        catch (Exception error) { ShowError("ErrorSave", error); }
    }

    private void OnSaveAs(object sender, RoutedEventArgs e)
    {
        if (selection is null) return;
        try
        {
            var extension = settings.ScreenshotFormat == ScreenshotFormat.Jpeg ? ".jpg" : ".png";
            var dialog = new SaveFileDialog
            {
                Title = Localizer.Get("SaveScreenshot"),
                Filter = "PNG image|*.png|JPEG image|*.jpg",
                FileName = Path.GetFileName(OutputNaming.NextPath(".", "Screenshot",
                    DateTimeOffset.Now, _ => false, extension)),
                OverwritePrompt = true
            };
            if (dialog.ShowDialog(this) != true) return;
            using var image = RenderSelection();
            ImageOutput.Save(image, dialog.FileName, overwrite: true);
            Close();
        }
        catch (Exception error) { ShowError("ErrorSave", error); }
    }

    private void ShowError(string key, Exception error) =>
        MessageBox.Show(this, $"{Localizer.Get(key)}: {error.Message}", "Skreen2Go",
            MessageBoxButton.OK, MessageBoxImage.Error);

    private void OnCancel(object sender, RoutedEventArgs e) => Close();

    private void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape) Close();
        else if (e.Key == Key.Return)
        { if (recordingMode) OnRecord(this, new RoutedEventArgs()); else OpenEditor(); }
        else if (!recordingMode && Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.C)
            OnCopy(this, new RoutedEventArgs());
        else if (!recordingMode && Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.S)
            OnSave(this, new RoutedEventArgs());
        else if (!recordingMode && Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.Z)
            OnUndo(this, new RoutedEventArgs());
        else if (!recordingMode && Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.Y)
            OnRedo(this, new RoutedEventArgs());
    }
}
