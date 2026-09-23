using System.Text.Json;
using System.Text.Json.Serialization;

namespace Skreen2Go.Windows.Core;

public enum ScreenshotFormat { Png, Jpeg }
public enum InterfaceLanguage { System, English, Russian }

public readonly record struct HotkeyCombination(int VirtualKey, uint Modifiers)
{
    public static HotkeyCombination DefaultCapture => new(0x53, 0x0002 | 0x0004);
    public static HotkeyCombination DefaultRecording => new(0x52, 0x0002 | 0x0004);
}

public sealed record AppSettings
{
    public int Version { get; init; } = 1;
    public string OutputFolder { get; init; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    public ScreenshotFormat ScreenshotFormat { get; init; } = ScreenshotFormat.Png;
    public InterfaceLanguage Language { get; init; } = InterfaceLanguage.System;
    public HotkeyCombination CaptureHotkey { get; init; } = HotkeyCombination.DefaultCapture;
    public HotkeyCombination RecordingHotkey { get; init; } = HotkeyCombination.DefaultRecording;
    public bool StartWithWindows { get; init; }
    public bool RecordSystemAudio { get; init; } = true;
    public bool RecordMicrophone { get; init; }
    public bool RecordCursor { get; init; } = true;
    public bool RecordClicks { get; init; }
    public uint AnnotationColor { get; init; } = 0xFFFF4B66;
    public float AnnotationThickness { get; init; } = 3;
    public float TextSize { get; init; } = 24;
    public int BlurRadius { get; init; } = 12;

    public static AppSettings Default => new();
}

public static class SettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Skreen2Go", "settings.json");

    public static AppSettings Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return AppSettings.Default;
            var settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), JsonOptions);
            return settings is null || !IsValid(settings) ? AppSettings.Default : settings;
        }
        catch (JsonException) { return AppSettings.Default; }
        catch (IOException) { return AppSettings.Default; }
        catch (UnauthorizedAccessException) { return AppSettings.Default; }
    }

    public static void Save(string path, AppSettings settings)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(settings);
        if (!IsValid(settings)) throw new ArgumentException("Settings contain invalid values.",
            nameof(settings));
        var folder = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(folder);
        var temp = Path.Combine(folder, $".{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temp, JsonSerializer.Serialize(settings, JsonOptions));
            File.Move(temp, path, overwrite: true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    private static bool IsValid(AppSettings settings) =>
        settings.Version == 1 &&
        !string.IsNullOrWhiteSpace(settings.OutputFolder) &&
        Enum.IsDefined(settings.ScreenshotFormat) &&
        Enum.IsDefined(settings.Language) &&
        IsHotkey(settings.CaptureHotkey) &&
        IsHotkey(settings.RecordingHotkey) &&
        settings.CaptureHotkey != settings.RecordingHotkey &&
        settings.AnnotationThickness is >= 1 and <= 20 &&
        settings.TextSize is >= 8 and <= 96 &&
        settings.BlurRadius is >= 1 and <= 40;

    private static bool IsHotkey(HotkeyCombination combination) =>
        (combination.VirtualKey is >= 0x41 and <= 0x5A ||
         combination.VirtualKey is >= 0x70 and <= 0x7B) &&
        combination.Modifiers is > 0 and <= 0x000F;
}
