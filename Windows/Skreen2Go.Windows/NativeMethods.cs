using System.Runtime.InteropServices;

namespace Skreen2Go.Windows;

internal static partial class NativeMethods
{
    internal const int WmHotkey = 0x0312;
    internal const uint ModControl = 0x0002;
    internal const uint ModShift = 0x0004;
    internal const uint VkS = 0x53;
    internal const uint VkR = 0x52;

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterHotKey(IntPtr window, int id);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y,
        int width, int height, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetCursorPos(out NativePoint point);

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativePoint { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeRect
    {
        public int Left, Top, Right, Bottom;
    }

    [LibraryImport("user32.dll")]
    internal static partial IntPtr GetTopWindow(IntPtr window);

    [LibraryImport("user32.dll")]
    internal static partial IntPtr GetWindow(IntPtr window, uint command);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool IsWindowVisible(IntPtr window);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool IsIconic(IntPtr window);

    [LibraryImport("user32.dll")]
    internal static partial uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetWindowRect(IntPtr window, out NativeRect rect);

    [LibraryImport("user32.dll")]
    internal static partial int GetWindowTextLengthW(IntPtr window);

    [LibraryImport("dwmapi.dll")]
    internal static partial int DwmGetWindowAttribute(IntPtr window, uint attribute,
        out NativeRect value, uint size);

    [LibraryImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")]
    internal static partial int DwmGetWindowAttributeInt(IntPtr window, uint attribute,
        out int value, uint size);
}
