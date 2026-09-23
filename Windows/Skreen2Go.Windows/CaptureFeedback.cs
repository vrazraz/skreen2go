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
    private readonly System.Windows.Shapes.Rectangle hand;
    private readonly RotateTransform handRotation = new();
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

        var handMask = new BitmapImage(new Uri(
            "pack://application:,,,/Skreen2Go.Windows;component/Resources/Hand.png"));
        hand = new System.Windows.Shapes.Rectangle
        {
            Width = 190,
            Height = 378,
            Fill = new SolidColorBrush(Color.FromRgb(245, 222, 205)),
            OpacityMask = new ImageBrush(handMask) { Stretch = Stretch.Fill },
            Effect = new DropShadowEffect
            {
                BlurRadius = 12, ShadowDepth = 5, Opacity = .3, Color = Colors.Black
            },
            RenderTransformOrigin = new WpfPoint(.5, .5),
            RenderTransform = handRotation
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

    private WpfPoint ToLocal(PointI screen) =>
        PointFromScreen(new WpfPoint(screen.X, screen.Y));

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

        var reach = Math.Clamp(seconds / .30, 0, 1);
        var retreat = Math.Clamp((seconds - .43) / .42, 0, 1);
        var handX = centreX + Math.Min(cardWidth * .35, 85);
        var handY = centreY - 345 + 95 * reach - 160 * retreat;
        Canvas.SetLeft(hand, handX);
        Canvas.SetTop(hand, handY);
        handRotation.Angle = -13 + 17 * reach - 10 * retreat;
        hand.Opacity = Math.Min(1, seconds / .10) *
            Math.Clamp((.87 - seconds) / .24, 0, 1);
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
