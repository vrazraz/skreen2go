using System.Runtime.InteropServices;
using Skreen2Go.Windows.Core;

namespace Skreen2Go.Windows;

internal static class WindowCatalog
{
    public static IReadOnlyList<RectangleI> TopToBottom(RectangleI desktop)
    {
        var result = new List<RectangleI>();
        var ownProcess = (uint)Environment.ProcessId;
        var window = NativeMethods.GetTopWindow(IntPtr.Zero);
        for (var count = 0; window != IntPtr.Zero && count < 1000; count++,
            window = NativeMethods.GetWindow(window, 2))
        {
            if (!NativeMethods.IsWindowVisible(window) || NativeMethods.IsIconic(window) ||
                NativeMethods.GetWindowTextLengthW(window) == 0)
                continue;
            NativeMethods.GetWindowThreadProcessId(window, out var processId);
            if (processId == ownProcess) continue;
            if (NativeMethods.DwmGetWindowAttributeInt(window, 14, out var cloaked, 4) == 0 &&
                cloaked != 0) continue;
            if (NativeMethods.DwmGetWindowAttribute(window, 9, out var bounds,
                    (uint)Marshal.SizeOf<NativeMethods.NativeRect>()) != 0 &&
                !NativeMethods.GetWindowRect(window, out bounds)) continue;
            var rect = SelectionGeometry.Clamp(
                new RectangleI(bounds.Left, bounds.Top,
                    bounds.Right - bounds.Left, bounds.Bottom - bounds.Top), desktop);
            if (rect.Width >= 10 && rect.Height >= 10) result.Add(rect);
        }
        return result;
    }
}
