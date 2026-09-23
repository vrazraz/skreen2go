using System.Drawing;
using System.IO;
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
    private Forms.ToolStripMenuItem? recordingMenuItem;
    private bool selectingRecording;
    private bool captureSystemAudio = true;
    private bool captureMicrophone;
    private CancellationTokenSource? countdown;
    private ScreenRecordingService? recording;
    private bool finalizingRecording;

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
        recordingMenuItem = new Forms.ToolStripMenuItem("Record area  Ctrl+Shift+R", null,
            (_, _) => Dispatcher.Invoke(OnRecordShortcut));
        tray.ContextMenuStrip.Items.Add(recordingMenuItem);
        var systemAudioItem = new Forms.ToolStripMenuItem("Record system audio")
        { CheckOnClick = true, Checked = captureSystemAudio };
        systemAudioItem.CheckedChanged += (_, _) => captureSystemAudio = systemAudioItem.Checked;
        tray.ContextMenuStrip.Items.Add(systemAudioItem);
        var microphoneItem = new Forms.ToolStripMenuItem("Record microphone")
        { CheckOnClick = true, Checked = captureMicrophone };
        microphoneItem.CheckedChanged += (_, _) => captureMicrophone = microphoneItem.Checked;
        tray.ContextMenuStrip.Items.Add(microphoneItem);
        tray.ContextMenuStrip.Items.Add("Exit", null, (_, _) => Dispatcher.Invoke(ExitAsync));
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
        if (!NativeMethods.RegisterHotKey(hotkeyWindow.Handle, 2,
            NativeMethods.ModControl | NativeMethods.ModShift, NativeMethods.VkR))
        {
            tray.ShowBalloonTip(4000, "Skreen2Go",
                "Ctrl+Shift+R is in use. Recording is available from the tray menu.",
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
        else if (message == NativeMethods.WmHotkey && wParam == (IntPtr)2)
        {
            Dispatcher.BeginInvoke(OnRecordShortcut, DispatcherPriority.Normal);
            handled = true;
        }
        return IntPtr.Zero;
    }

    private void BeginCapture()
    {
        if (captureWindow is not null) { captureWindow.Activate(); return; }
        OpenSelection(recordingMode: false);
    }

    private void OpenSelection(bool recordingMode)
    {
        try
        {
            desktop = DesktopCapture.Snapshot();
            selectingRecording = recordingMode;
            captureWindow = new CaptureWindow(desktop, recordingMode);
            captureWindow.CaptureAccepted += recordingMode ? OnRecordingSelected : OnCaptureAccepted;
            captureWindow.Closed += (_, _) =>
            {
                captureWindow = null;
                selectingRecording = false;
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

    private void OnRecordShortcut()
    {
        if (finalizingRecording) return;
        if (recording is not null)
        {
            _ = StopRecordingAsync();
            return;
        }
        if (countdown is not null)
        {
            countdown.Cancel();
            countdown.Dispose();
            countdown = null;
            tray!.Text = "Skreen2Go";
            return;
        }
        if (captureWindow is not null)
        {
            if (selectingRecording) captureWindow.Close();
            else captureWindow.Activate();
            return;
        }
        OpenSelection(recordingMode: true);
    }

    private void OnRecordingSelected(RectangleI selection)
    {
        try
        {
            var displays = Forms.Screen.AllScreens.Select(screen =>
                new RecordingDisplay(screen.DeviceName,
                    new RectangleI(screen.Bounds.X, screen.Bounds.Y,
                        screen.Bounds.Width, screen.Bounds.Height))).ToArray();
            var plan = RecordingGeometry.Plan(selection, displays);
            if (plan.TrimmedToOneDisplay)
                tray!.ShowBalloonTip(3000, "Skreen2Go",
                    "The recording area was trimmed to one display.", Forms.ToolTipIcon.Info);
            _ = StartAfterCountdownAsync(plan);
        }
        catch (Exception error)
        {
            MessageBox.Show($"Cannot select recording area: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async Task StartAfterCountdownAsync(RecordingPlan plan)
    {
        var pending = new CancellationTokenSource();
        countdown = pending;
        tray!.Text = "Skreen2Go — recording starts in 3 seconds";
        recordingMenuItem!.Text = "Cancel countdown  Ctrl+Shift+R";
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(3), pending.Token);
            if (countdown != pending) return;
            countdown = null;
            var folder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            var path = OutputNaming.NextPath(folder, "Recording", DateTimeOffset.Now,
                File.Exists, ".mp4");
            recording = new ScreenRecordingService();
            recording.Start(plan, path, captureSystemAudio, captureMicrophone);
            tray.Text = "Skreen2Go — recording";
            tray.Icon = SystemIcons.Error;
            recordingMenuItem.Text = "Stop recording  Ctrl+Shift+R";
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            recording?.Dispose();
            recording = null;
            MessageBox.Show($"Cannot start recording: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            if (countdown == pending) countdown = null;
            pending.Dispose();
            if (recording is null)
            {
                tray.Text = "Skreen2Go";
                recordingMenuItem.Text = "Record area  Ctrl+Shift+R";
            }
        }
    }

    private async Task StopRecordingAsync()
    {
        var active = recording;
        if (active is null) return;
        finalizingRecording = true;
        recording = null;
        tray!.Text = "Skreen2Go — finalizing recording";
        recordingMenuItem!.Enabled = false;
        try
        {
            var path = await active.StopAsync();
            tray.ShowBalloonTip(5000, "Recording saved",
                path, Forms.ToolTipIcon.Info);
        }
        catch (Exception error)
        {
            MessageBox.Show($"Cannot finish recording: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            active.Dispose();
            finalizingRecording = false;
            tray.Text = "Skreen2Go";
            tray.Icon = SystemIcons.Application;
            recordingMenuItem.Enabled = true;
            recordingMenuItem.Text = "Record area  Ctrl+Shift+R";
        }
    }

    private async void ExitAsync()
    {
        if (recording is not null) await StopRecordingAsync();
        Shutdown();
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
            NativeMethods.UnregisterHotKey(hotkeyWindow.Handle, 2);
            hotkeyWindow.Dispose();
        }
        countdown?.Cancel();
        countdown?.Dispose();
        recording?.Dispose();
        tray?.Dispose();
        desktop?.Dispose();
        base.OnExit(e);
    }
}
