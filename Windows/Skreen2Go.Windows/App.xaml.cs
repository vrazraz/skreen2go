using System.Drawing;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;
using Skreen2Go.Windows.Core;
using Forms = System.Windows.Forms;
using MessageBox = System.Windows.MessageBox;

namespace Skreen2Go.Windows;

public partial class App : System.Windows.Application
{
    private Forms.NotifyIcon? tray;
    private Icon? appIcon;
    private HwndSource? hotkeyWindow;
    private CaptureWindow? captureWindow;
    private DesktopCapture? desktop;
    private Forms.ToolStripMenuItem? recordingMenuItem;
    private Forms.ToolStripMenuItem? captureMenuItem;
    private Forms.ToolStripMenuItem? settingsMenuItem;
    private Forms.ToolStripMenuItem? exitMenuItem;
    private Forms.ToolStripMenuItem? systemAudioItem;
    private Forms.ToolStripMenuItem? microphoneItem;
    private SettingsWindow? settingsWindow;
    private AppSettings settings = AppSettings.Default;
    private bool updatingTraySettings;
    private bool selectingRecording;
    private CancellationTokenSource? countdown;
    private ScreenRecordingService? recording;
    private bool finalizingRecording;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        settings = SettingsStore.Load(SettingsStore.DefaultPath);
        Localizer.Apply(settings.Language);
        appIcon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? "")
            ?? SystemIcons.Application;
        tray = new Forms.NotifyIcon
        {
            Icon = appIcon,
            Text = "Skreen2Go",
            Visible = true,
            ContextMenuStrip = new Forms.ContextMenuStrip()
        };
        captureMenuItem = new Forms.ToolStripMenuItem("", null,
            (_, _) => Dispatcher.Invoke(BeginCapture));
        tray.ContextMenuStrip.Items.Add(captureMenuItem);
        recordingMenuItem = new Forms.ToolStripMenuItem("", null,
            (_, _) => Dispatcher.Invoke(OnRecordShortcut));
        tray.ContextMenuStrip.Items.Add(recordingMenuItem);
        systemAudioItem = new Forms.ToolStripMenuItem("")
        { CheckOnClick = true, Checked = settings.RecordSystemAudio };
        systemAudioItem.CheckedChanged += (_, _) => SaveQuickAudioSettings();
        tray.ContextMenuStrip.Items.Add(systemAudioItem);
        microphoneItem = new Forms.ToolStripMenuItem("")
        { CheckOnClick = true, Checked = settings.RecordMicrophone };
        microphoneItem.CheckedChanged += (_, _) => SaveQuickAudioSettings();
        tray.ContextMenuStrip.Items.Add(microphoneItem);
        settingsMenuItem = new Forms.ToolStripMenuItem("", null,
            (_, _) => Dispatcher.Invoke(OpenSettings));
        tray.ContextMenuStrip.Items.Add(settingsMenuItem);
        exitMenuItem = new Forms.ToolStripMenuItem("", null,
            (_, _) => Dispatcher.Invoke(ExitAsync));
        tray.ContextMenuStrip.Items.Add(exitMenuItem);
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(BeginCapture);
        RefreshTrayText();

        var parameters = new HwndSourceParameters("Skreen2Go hotkey")
        {
            Width = 0, Height = 0, WindowStyle = 0
        };
        hotkeyWindow = new HwndSource(parameters);
        hotkeyWindow.AddHook(HotkeyHook);
        if (!NativeMethods.RegisterHotKey(hotkeyWindow.Handle, 1,
            settings.CaptureHotkey.Modifiers, (uint)settings.CaptureHotkey.VirtualKey))
        {
            tray.ShowBalloonTip(4000, "Skreen2Go", Localizer.Get("HotkeyInUse"),
                Forms.ToolTipIcon.Warning);
        }
        if (!NativeMethods.RegisterHotKey(hotkeyWindow.Handle, 2,
            settings.RecordingHotkey.Modifiers, (uint)settings.RecordingHotkey.VirtualKey))
        {
            tray.ShowBalloonTip(4000, "Skreen2Go", Localizer.Get("HotkeyInUse"),
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

    private void OpenSettings()
    {
        if (settingsWindow is not null) { settingsWindow.Activate(); return; }
        var window = new SettingsWindow(settings);
        settingsWindow = window;
        window.Closed += (_, _) => settingsWindow = null;
        if (window.ShowDialog() != true || window.Result is null) return;
        try { ApplySettings(window.Result); }
        catch (Exception error)
        {
            MessageBox.Show($"{Localizer.Get("ErrorSettings")}: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void SaveQuickAudioSettings()
    {
        if (updatingTraySettings || systemAudioItem is null || microphoneItem is null) return;
        var changed = settings with
        {
            RecordSystemAudio = systemAudioItem.Checked,
            RecordMicrophone = microphoneItem.Checked
        };
        try
        {
            SettingsStore.Save(SettingsStore.DefaultPath, changed);
            settings = changed;
        }
        catch (Exception error)
        {
            updatingTraySettings = true;
            systemAudioItem.Checked = settings.RecordSystemAudio;
            microphoneItem.Checked = settings.RecordMicrophone;
            updatingTraySettings = false;
            MessageBox.Show($"{Localizer.Get("ErrorAudioSettings")}: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void ApplySettings(AppSettings proposed)
    {
        var handle = hotkeyWindow!.Handle;
        NativeMethods.UnregisterHotKey(handle, 1);
        NativeMethods.UnregisterHotKey(handle, 2);
        var first = NativeMethods.RegisterHotKey(handle, 1,
            proposed.CaptureHotkey.Modifiers, (uint)proposed.CaptureHotkey.VirtualKey);
        var second = first && NativeMethods.RegisterHotKey(handle, 2,
            proposed.RecordingHotkey.Modifiers, (uint)proposed.RecordingHotkey.VirtualKey);
        if (!first || !second)
        {
            NativeMethods.UnregisterHotKey(handle, 1);
            NativeMethods.UnregisterHotKey(handle, 2);
            RegisterCurrentHotkeys(handle);
            throw new InvalidOperationException(Localizer.Get("ShortcutInUse"));
        }
        try
        {
            ConfigureAutostart(proposed.StartWithWindows);
            SettingsStore.Save(SettingsStore.DefaultPath, proposed);
            settings = proposed;
            Localizer.Apply(proposed.Language);
            updatingTraySettings = true;
            systemAudioItem!.Checked = proposed.RecordSystemAudio;
            microphoneItem!.Checked = proposed.RecordMicrophone;
            updatingTraySettings = false;
            RefreshTrayText();
        }
        catch
        {
            NativeMethods.UnregisterHotKey(handle, 1);
            NativeMethods.UnregisterHotKey(handle, 2);
            RegisterCurrentHotkeys(handle);
            try { ConfigureAutostart(settings.StartWithWindows); } catch { }
            throw;
        }
    }

    private void RegisterCurrentHotkeys(IntPtr handle)
    {
        NativeMethods.RegisterHotKey(handle, 1, settings.CaptureHotkey.Modifiers,
            (uint)settings.CaptureHotkey.VirtualKey);
        NativeMethods.RegisterHotKey(handle, 2, settings.RecordingHotkey.Modifiers,
            (uint)settings.RecordingHotkey.VirtualKey);
    }

    private void RefreshTrayText()
    {
        if (captureMenuItem is null || recordingMenuItem is null ||
            systemAudioItem is null || microphoneItem is null ||
            settingsMenuItem is null || exitMenuItem is null) return;
        captureMenuItem.Text = $"{Localizer.Get("TrayCapture")}  {Describe(settings.CaptureHotkey)}";
        var recordKey = countdown is not null ? "TrayCancelCountdown" :
            recording is not null ? "TrayStop" : "TrayRecord";
        recordingMenuItem.Text = $"{Localizer.Get(recordKey)}  {Describe(settings.RecordingHotkey)}";
        systemAudioItem.Text = Localizer.Get("TraySystemAudio");
        microphoneItem.Text = Localizer.Get("TrayMicrophone");
        settingsMenuItem.Text = Localizer.Get("TraySettings");
        exitMenuItem.Text = Localizer.Get("TrayExit");
    }

    private static string Describe(HotkeyCombination hotkey)
    {
        var parts = new List<string>();
        if ((hotkey.Modifiers & 0x0002) != 0) parts.Add("Ctrl");
        if ((hotkey.Modifiers & 0x0001) != 0) parts.Add("Alt");
        if ((hotkey.Modifiers & 0x0004) != 0) parts.Add("Shift");
        if ((hotkey.Modifiers & 0x0008) != 0) parts.Add("Win");
        parts.Add(hotkey.VirtualKey is >= 0x70 and <= 0x7B
            ? $"F{hotkey.VirtualKey - 0x6F}" : ((char)hotkey.VirtualKey).ToString());
        return string.Join("+", parts);
    }

    private static void ConfigureAutostart(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Run", writable: true)
            ?? throw new InvalidOperationException("Cannot open the Windows startup settings.");
        if (!enabled) { key.DeleteValue("Skreen2Go", throwOnMissingValue: false); return; }
        var process = Environment.ProcessPath
            ?? throw new InvalidOperationException("Cannot find the application path.");
        var command = Path.GetFileName(process).Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase)
            ? $"\"{process}\" \"{Environment.GetCommandLineArgs()[0]}\""
            : $"\"{process}\"";
        key.SetValue("Skreen2Go", command);
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
            MessageBox.Show($"{Localizer.Get("ErrorCapture")}: {error.Message}", "Skreen2Go",
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
            RefreshTrayText();
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
                    Localizer.Get("RecordingTrimmed"), Forms.ToolTipIcon.Info);
            _ = StartAfterCountdownAsync(plan);
        }
        catch (Exception error)
        {
            MessageBox.Show($"{Localizer.Get("ErrorRecordSelect")}: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async Task StartAfterCountdownAsync(RecordingPlan plan)
    {
        var pending = new CancellationTokenSource();
        countdown = pending;
        tray!.Text = Localizer.Get("TrayCountdown");
        RefreshTrayText();
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(3), pending.Token);
            if (countdown != pending) return;
            countdown = null;
            var folder = settings.OutputFolder;
            var path = OutputNaming.NextPath(folder, "Recording", DateTimeOffset.Now,
                File.Exists, ".mp4");
            recording = new ScreenRecordingService();
            recording.Start(plan, path, settings.RecordSystemAudio, settings.RecordMicrophone,
                settings.RecordCursor, settings.RecordClicks);
            tray.Text = Localizer.Get("TrayRecording");
            tray.Icon = SystemIcons.Error;
            RefreshTrayText();
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            recording?.Dispose();
            recording = null;
            MessageBox.Show($"{Localizer.Get("ErrorRecordStart")}: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            if (countdown == pending) countdown = null;
            pending.Dispose();
            if (recording is null)
            {
                tray.Text = "Skreen2Go";
                RefreshTrayText();
            }
        }
    }

    private async Task StopRecordingAsync()
    {
        var active = recording;
        if (active is null) return;
        finalizingRecording = true;
        recording = null;
        tray!.Text = Localizer.Get("TrayFinalizing");
        recordingMenuItem!.Enabled = false;
        try
        {
            var path = await active.StopAsync();
            tray.ShowBalloonTip(5000, Localizer.Get("RecordingSaved"),
                path, Forms.ToolTipIcon.Info);
        }
        catch (Exception error)
        {
            MessageBox.Show($"{Localizer.Get("ErrorRecordFinish")}: {error.Message}", "Skreen2Go",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            active.Dispose();
            finalizingRecording = false;
            tray.Text = "Skreen2Go";
            tray.Icon = appIcon;
            recordingMenuItem.Enabled = true;
            RefreshTrayText();
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
            var editor = new EditorWindow(cropped, settings);
            editor.Show();
        }
        catch (Exception error)
        {
            MessageBox.Show($"{Localizer.Get("ErrorCrop")}: {error.Message}", "Skreen2Go",
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
        if (appIcon != SystemIcons.Application) appIcon?.Dispose();
        desktop?.Dispose();
        base.OnExit(e);
    }
}
