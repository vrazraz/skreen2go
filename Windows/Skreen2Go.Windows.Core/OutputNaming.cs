using System.Globalization;

namespace Skreen2Go.Windows.Core;

public static class OutputNaming
{
    public static string NextPath(string folder, string prefix, DateTimeOffset when,
        Func<string, bool> exists, string extension = ".png")
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(folder);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);
        ArgumentNullException.ThrowIfNull(exists);

        var stem = $"{prefix} {when.ToString("yyyy-MM-dd 'at' HH.mm.ss", CultureInfo.InvariantCulture)}";
        var path = Path.Combine(folder, stem + extension);
        for (var suffix = 2; exists(path); suffix++)
            path = Path.Combine(folder, $"{stem} ({suffix}){extension}");
        return path;
    }
}
