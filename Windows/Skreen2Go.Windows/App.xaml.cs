using System.Drawing;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Skreen2Go.Windows.Core;
using Forms = System.Windows.Forms;
using MessageBox = System.Windows.MessageBox;

namespace Skreen2Go.Windows;

public partial class App : System.Windows.Application
{
    private Forms.NotifyIcon? tray;
    private HwndSource? hotkeyWindow;
    private CaptureWindow? captureWindow;
    private DesktopCapture? desktop;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        tray = new Forms.NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "Skreen2Go",
            Visible = true,
            ContextMenuStrip = new Forms.ContextMenuStrip()
        };
        tray.ContextMenuStrip.Items.Add("Capture  Ctrl+Shift+S", null,
            (_, _) => Dispatcher.Invoke(BeginCapture));
        tray.ContextMenuStrip.Items.Add("Exit", null, (_, _) => Dispatcher.Invoke(Shutdown));
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(BeginCapture);

        var parameters = new HwndSourceParameters("Skreen2Go hotkey")
        {
            Width = 0, Height = 0, WindowStyle = 0
        };
        hotkeyWindow = new HwndSource(parameters);
        hotkeyWindow.AddHook(HotkeyHook);
        if (!NativeMethods.RegisterHotKey(hotkeyWindow.Handle, 1,
            NativeMethods.ModControl | NativeMethods.ModShift, NativeMethods.VkS))
        {
            tray.ShowBalloonTip(4000, "Skreen2Go",
                "Ctrl+Shift+S is in use. Capture is available from the tray menu.",
                Forms.ToolTipIcon.Warning);
        }
    }

    private IntPtr HotkeyHook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam,
        ref bool handled)
    {
        if (message == NativeMethods.WmHotkey && wParam == (IntPtr)1)
        {
            Dispatcher.BeginInvoke(BeginCapture, DispatcherPriority.Normal);
            handled = true;
        }
        return IntPtr.Zero;
    }

    private void BeginCapture()
    {
        if (captureWindow is not null) { captureWindow.Activate(); return; }
        try
        {
            desktop = DesktopCapture.Snapshot();
            captureWindow = new CaptureWindow(desktop);
            captureWindow.CaptureAccepted += OnCaptureAccepted;
            captureWindow.Closed += (_, _) =>
            {
                captureWindow = null;
                desktop?.Dispose();
                desktop = null;
            };
            captureWindow.Show();
        }
        catch (Exception error)
        {
            desktop?.Dispose();
            desktop = null;
            MessageBox.Show($"Cannot capture the desktop: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OnCaptureAccepted(RectangleI selection)
    {
        if (desktop is null) return;
        try
        {
            var cropped = desktop.Crop(selection);
            var editor = new EditorWindow(cropped);
            editor.Show();
        }
        catch (Exception error)
        {
            MessageBox.Show($"Cannot crop selection: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (hotkeyWindow is not null)
        {
            NativeMethods.UnregisterHotKey(hotkeyWindow.Handle, 1);
            hotkeyWindow.Dispose();
        }
        tray?.Dispose();
        desktop?.Dispose();
        base.OnExit(e);
    }
}
