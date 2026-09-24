using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using Skreen2Go.Windows.Core;
using Forms = System.Windows.Forms;
using WpfPoint = System.Windows.Point;
using Brushes = System.Windows.Media.Brushes;
using Image = System.Windows.Controls.Image;
using Color = System.Windows.Media.Color;

namespace Skreen2Go.Windows;

/// <summary>A click-through flourish after the image has reached the clipboard.</summary>
internal sealed class CaptureFeedback : Window
{
    private readonly Canvas canvas = new();
    private readonly Border thumbnail;
    private readonly Image hand;
    private static readonly Lazy<BitmapImage[]> handFrames = new(LoadHandFrames);
    private BitmapImage[]? frames;
    private readonly Stopwatch clock = new();
    private readonly RectangleI sourceRect;
    private readonly PointI trayPoint;
    private readonly double aspect;
    private Rect origin;
    private WpfPoint destination;
    private double cardWidth;
    private double cardHeight;

    private CaptureFeedback(BitmapSource image, RectangleI sourceRect)
    {
        this.sourceRect = sourceRect;
        trayPoint = FindTrayTarget();
        aspect = image.PixelHeight / (double)Math.Max(1, image.PixelWidth);
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        Topmost = true;
        IsHitTestVisible = false;
        Width = SystemParameters.VirtualScreenWidth;
        Height = SystemParameters.VirtualScreenHeight;
        Left = SystemParameters.VirtualScreenLeft;
        Top = SystemParameters.VirtualScreenTop;

        thumbnail = new Border
        {
            BorderBrush = Brushes.White,
            BorderThickness = new Thickness(2),
            CornerRadius = new CornerRadius(5),
            Background = Brushes.White,
            Child = new Image { Source = image, Stretch = Stretch.Fill },
            Effect = new DropShadowEffect
            {
                BlurRadius = 18, ShadowDepth = 7, Opacity = .44, Color = Colors.Black
            }
        };
        canvas.Children.Add(thumbnail);

        hand = new Image
        {
            Stretch = Stretch.Fill,
            IsHitTestVisible = false
        };
        canvas.Children.Add(hand);
        Content = canvas;
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle,
                new IntPtr(style | NativeMethods.WsExTransparent |
                    NativeMethods.WsExToolWindow | NativeMethods.WsExNoActivate));
            NativeMethods.SetWindowPos(handle, IntPtr.Zero,
                (int)SystemParameters.VirtualScreenLeft,
                (int)SystemParameters.VirtualScreenTop,
                (int)SystemParameters.VirtualScreenWidth,
                (int)SystemParameters.VirtualScreenHeight, 0x0040);
        };
        Loaded += (_, _) =>
        {
            origin = new Rect(ToLocal(new PointI(sourceRect.X, sourceRect.Y)),
                ToLocal(new PointI(sourceRect.Right, sourceRect.Bottom)));
            destination = ToLocal(trayPoint);
            cardWidth = Math.Clamp(origin.Width * .75, 90, 300);
            cardHeight = Math.Clamp(cardWidth * aspect, 45, 210);
            PlaceHand();
            try { frames = handFrames.Value; hand.Source = frames[0]; }
            catch { hand.Visibility = Visibility.Collapsed; }
            clock.Start();
            CompositionTarget.Rendering += RenderFrame;
        };
        Closed += (_, _) => CompositionTarget.Rendering -= RenderFrame;
    }

    public static void Play(BitmapSource image, RectangleI sourceRect)
    {
        try { new CaptureFeedback(image, sourceRect).Show(); }
        catch { /* The visual is optional; clipboard content is already available. */ }
    }

    public static void Prepare()
    {
        try { _ = handFrames.Value; }
        catch { /* Clipboard feedback remains optional. */ }
    }

    private WpfPoint ToLocal(PointI screen) =>
        PointFromScreen(new WpfPoint(screen.X, screen.Y));

    private static BitmapImage[] LoadHandFrames()
    {
        var frames = new BitmapImage[49];
        for (var index = 0; index < frames.Length; index++)
        {
            var image = new BitmapImage(new Uri(
                $"pack://application:,,,/Skreen2Go.Windows;component/Resources/HandFrames/{index:000}.png"));
            image.Freeze();
            frames[index] = image;
        }
        return frames;
    }

    private void PlaceHand()
    {
        var centre = new System.Drawing.Point(sourceRect.X + sourceRect.Width / 2,
            sourceRect.Y + sourceRect.Height / 2);
        var screen = Forms.Screen.FromPoint(centre).Bounds;
        var width = Math.Min(screen.Width * .62, 1000);
        var height = width * 982 / 1512;
        var left = Clamp(centre.X - width / 2, screen.Left, screen.Right - width);
        // AppKit's positive Y points upward; WPF's points downward.
        var top = Clamp(centre.Y - height / 2 - height * .15,
            screen.Top, screen.Bottom - height);
        var start = ToLocal(new PointI((int)Math.Round(left), (int)Math.Round(top)));
        var end = ToLocal(new PointI((int)Math.Round(left + width),
            (int)Math.Round(top + height)));
        hand.Width = end.X - start.X;
        hand.Height = end.Y - start.Y;
        Canvas.SetLeft(hand, start.X);
        Canvas.SetTop(hand, start.Y);
    }

    private static double Clamp(double value, double lower, double upper) =>
        upper > lower ? Math.Clamp(value, lower, upper) : (lower + upper) / 2;

    private void RenderFrame(object? sender, EventArgs e)
    {
        var seconds = clock.Elapsed.TotalSeconds;
        if (seconds > 1.18) { Close(); return; }

        var centreX = origin.Left + origin.Width / 2;
        var centreY = origin.Top + origin.Height / 2;
        var flight = Math.Clamp((seconds - .25) / .79, 0, 1);
        var ease = flight * flight * (3 - 2 * flight);
        var x = centreX + (destination.X - centreX) * ease;
        var y = centreY + (destination.Y - centreY) * ease -
            Math.Sin(Math.PI * flight) * 105;
        var scale = 1 - .86 * ease;
        thumbnail.Width = cardWidth * scale;
        thumbnail.Height = cardHeight * scale;
        thumbnail.Opacity = Math.Clamp((1.11 - seconds) / .15, 0, 1);
        Canvas.SetLeft(thumbnail, x - thumbnail.Width / 2);
        Canvas.SetTop(thumbnail, y - thumbnail.Height / 2);

        var index = (int)(seconds * 60);
        if (frames is not null)
            hand.Source = index < frames.Length ? frames[index] : null;
    }

    private static PointI FindTrayTarget()
    {
        var taskbar = NativeMethods.FindWindow("Shell_TrayWnd", null);
        if (taskbar != IntPtr.Zero)
        {
            var notification = NativeMethods.FindWindowEx(taskbar, IntPtr.Zero,
                "TrayNotifyWnd", null);
            if (notification != IntPtr.Zero &&
                NativeMethods.GetWindowRect(notification, out var area))
                return new PointI((area.Left + area.Right) / 2,
                    (area.Top + area.Bottom) / 2);
            if (NativeMethods.GetWindowRect(taskbar, out var bar))
                return new PointI(bar.Right - 55, (bar.Top + bar.Bottom) / 2);
        }
        var screen = Forms.Screen.PrimaryScreen?.Bounds ??
            new System.Drawing.Rectangle(0, 0, 1920, 1080);
        return new PointI(screen.Right - 52, screen.Bottom - 30);
    }
}
