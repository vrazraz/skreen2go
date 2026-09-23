using System.Windows;
using System.Windows.Input;
using Skreen2Go.Windows.Core;
using Forms = System.Windows.Forms;

namespace Skreen2Go.Windows;

public partial class SettingsWindow : Window
{
    private AppSettings settings;
    private HotkeyCombination captureHotkey;
    private HotkeyCombination recordingHotkey;
    private uint color;

    public AppSettings? Result { get; private set; }

    public SettingsWindow(AppSettings current)
    {
        settings = current;
        captureHotkey = current.CaptureHotkey;
        recordingHotkey = current.RecordingHotkey;
        color = current.AnnotationColor;
        InitializeComponent();
        FormatBox.ItemsSource = Enum.GetValues<ScreenshotFormat>();
        LanguageBox.ItemsSource = Enum.GetValues<InterfaceLanguage>();
        Populate(current);
    }

    private void Populate(AppSettings current)
    {
        FolderBox.Text = current.OutputFolder;
        FormatBox.SelectedItem = current.ScreenshotFormat;
        LanguageBox.SelectedItem = current.Language;
        captureHotkey = current.CaptureHotkey;
        recordingHotkey = current.RecordingHotkey;
        CaptureHotkeyBox.Text = Describe(captureHotkey);
        RecordingHotkeyBox.Text = Describe(recordingHotkey);
        StartWithWindowsBox.IsChecked = current.StartWithWindows;
        SystemAudioBox.IsChecked = current.RecordSystemAudio;
        MicrophoneBox.IsChecked = current.RecordMicrophone;
        CursorBox.IsChecked = current.RecordCursor;
        ClicksBox.IsChecked = current.RecordClicks;
        color = current.AnnotationColor;
        ColorButton.BorderBrush = new System.Windows.Media.SolidColorBrush(
            System.Windows.Media.Color.FromArgb((byte)(color >> 24),
                (byte)(color >> 16), (byte)(color >> 8), (byte)color));
        ThicknessSlider.Value = current.AnnotationThickness;
        TextSizeSlider.Value = current.TextSize;
        BlurSlider.Value = current.BlurRadius;
        ErrorText.Text = "";
    }

    private static string Describe(HotkeyCombination combination)
    {
        var parts = new List<string>();
        if ((combination.Modifiers & 0x0002) != 0) parts.Add("Ctrl");
        if ((combination.Modifiers & 0x0001) != 0) parts.Add("Alt");
        if ((combination.Modifiers & 0x0004) != 0) parts.Add("Shift");
        if ((combination.Modifiers & 0x0008) != 0) parts.Add("Win");
        parts.Add(combination.VirtualKey is >= 0x70 and <= 0x7B
            ? $"F{combination.VirtualKey - 0x6F}"
            : ((char)combination.VirtualKey).ToString());
        return string.Join("+", parts);
    }

    private static HotkeyCombination? FromKeyEvent(System.Windows.Input.KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var virtualKey = KeyInterop.VirtualKeyFromKey(key);
        if (virtualKey is not (>= 0x41 and <= 0x5A or >= 0x70 and <= 0x7B))
            return null;
        uint modifiers = 0;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) modifiers |= 0x0002;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) modifiers |= 0x0001;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) modifiers |= 0x0004;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows)) modifiers |= 0x0008;
        return modifiers == 0 ? null : new HotkeyCombination(virtualKey, modifiers);
    }

    private void OnCaptureHotkey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        e.Handled = true;
        var next = FromKeyEvent(e);
        if (next is null) return;
        captureHotkey = next.Value;
        CaptureHotkeyBox.Text = Describe(captureHotkey);
    }

    private void OnRecordingHotkey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        e.Handled = true;
        var next = FromKeyEvent(e);
        if (next is null) return;
        recordingHotkey = next.Value;
        RecordingHotkeyBox.Text = Describe(recordingHotkey);
    }

    private void OnBrowse(object sender, RoutedEventArgs e)
    {
        using var dialog = new Forms.FolderBrowserDialog
        {
            Description = "Choose where screenshots and recordings are saved",
            InitialDirectory = FolderBox.Text,
            UseDescriptionForTitle = true
        };
        if (dialog.ShowDialog() == Forms.DialogResult.OK) FolderBox.Text = dialog.SelectedPath;
    }

    private void OnColor(object sender, RoutedEventArgs e)
    {
        using var dialog = new Forms.ColorDialog
        {
            Color = System.Drawing.Color.FromArgb((int)color),
            FullOpen = true
        };
        if (dialog.ShowDialog() != Forms.DialogResult.OK) return;
        color = (uint)dialog.Color.ToArgb();
        ColorButton.BorderBrush = new System.Windows.Media.SolidColorBrush(
            System.Windows.Media.Color.FromArgb(dialog.Color.A, dialog.Color.R,
                dialog.Color.G, dialog.Color.B));
    }

    private void OnReset(object sender, RoutedEventArgs e) => Populate(AppSettings.Default);
    private void OnCancel(object sender, RoutedEventArgs e) => DialogResult = false;

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (captureHotkey == recordingHotkey)
        {
            ErrorText.Text = "The two hotkeys must differ.";
            return;
        }
        if (string.IsNullOrWhiteSpace(FolderBox.Text))
        {
            ErrorText.Text = "Choose a save folder.";
            return;
        }
        Result = settings with
        {
            OutputFolder = FolderBox.Text.Trim(),
            ScreenshotFormat = (ScreenshotFormat)FormatBox.SelectedItem,
            Language = (InterfaceLanguage)LanguageBox.SelectedItem,
            CaptureHotkey = captureHotkey,
            RecordingHotkey = recordingHotkey,
            StartWithWindows = StartWithWindowsBox.IsChecked == true,
            RecordSystemAudio = SystemAudioBox.IsChecked == true,
            RecordMicrophone = MicrophoneBox.IsChecked == true,
            RecordCursor = CursorBox.IsChecked == true,
            RecordClicks = ClicksBox.IsChecked == true,
            AnnotationColor = color,
            AnnotationThickness = (float)ThicknessSlider.Value,
            TextSize = (float)TextSizeSlider.Value,
            BlurRadius = (int)BlurSlider.Value
        };
        DialogResult = true;
    }
}
