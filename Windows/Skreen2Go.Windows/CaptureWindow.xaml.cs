using System.Drawing;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Skreen2Go.Windows.Core;

namespace Skreen2Go.Windows;

public partial class CaptureWindow : Window
{
    private readonly DesktopCapture capture;
    private PointI? start;
    private PointI? end;

    public event Action<RectangleI>? CaptureAccepted;

    internal CaptureWindow(DesktopCapture capture, bool recording = false)
    {
        this.capture = capture;
        InitializeComponent();
        if (recording)
            Instruction.SetResourceReference(System.Windows.Controls.TextBlock.TextProperty,
                "RecordingHint");
        var source = BitmapSourceFromBitmap(capture.Bitmap);
        DimmedImage.Source = source;
        SelectedImage.Source = source;
        Loaded += (_, _) => { Activate(); Focus(); };
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            NativeMethods.SetWindowPos(handle, IntPtr.Zero, capture.Bounds.X, capture.Bounds.Y,
                capture.Bounds.Width, capture.Bounds.Height, 0x0040);
        };
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

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!NativeMethods.GetCursorPos(out var cursor)) return;
        start = new PointI(cursor.X, cursor.Y);
        end = start;
        CaptureMouse();
        DrawSelection();
    }

    private void OnMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (start is null || !NativeMethods.GetCursorPos(out var cursor)) return;
        end = new PointI(cursor.X, cursor.Y);
        DrawSelection();
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (start is null || !NativeMethods.GetCursorPos(out var cursor)) return;
        end = new PointI(cursor.X, cursor.Y);
        ReleaseMouseCapture();
        var selection = SelectionGeometry.Clamp(SelectionGeometry.Normalize(start.Value, end.Value),
            capture.Bounds);
        var clickPoint = start.Value;
        start = null;
        if (selection.Width < 2 || selection.Height < 2)
        {
            var window = capture.WindowAt(clickPoint);
            if (window is null) { DrawSelection(); return; }
            selection = window.Value;
        }
        CaptureAccepted?.Invoke(selection);
        Close();
    }

    private void DrawSelection()
    {
        if (start is null || end is null)
        {
            SelectionBorder.Visibility = Visibility.Collapsed;
            SelectedImage.Clip = Geometry.Empty;
            return;
        }
        var rect = SelectionGeometry.Clamp(SelectionGeometry.Normalize(start.Value, end.Value),
            capture.Bounds);
        var topLeft = PointFromScreen(new System.Windows.Point(rect.X, rect.Y));
        var bottomRight = PointFromScreen(new System.Windows.Point(rect.Right, rect.Bottom));
        var width = Math.Max(0, bottomRight.X - topLeft.X);
        var height = Math.Max(0, bottomRight.Y - topLeft.Y);
        Canvas.SetLeft(SelectionBorder, topLeft.X);
        Canvas.SetTop(SelectionBorder, topLeft.Y);
        SelectionBorder.Width = width;
        SelectionBorder.Height = height;
        SelectionBorder.Visibility = Visibility.Visible;
        SelectedImage.Clip = new RectangleGeometry(new Rect(topLeft.X, topLeft.Y, width, height));
    }

    private void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape) Close();
    }
}
