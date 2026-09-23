using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Brush = System.Windows.Media.Brush;
using Point = System.Windows.Point;
using TextBox = System.Windows.Controls.TextBox;
using FontFamily = System.Windows.Media.FontFamily;
using Panel = System.Windows.Controls.Panel;

namespace Skreen2Go.Windows;

internal static class InlineTextEntry
{
    public static TextBox Show(Canvas host, Point point, double fontSize, Brush foreground,
        double maxWidth, Action<string> onAccept, Action onFinish)
    {
        var ink = (foreground as SolidColorBrush)?.Color ?? Colors.White;
        var darkInk = ink.R * .2126 + ink.G * .7152 + ink.B * .0722 < 80;
        var editor = new TextBox
        {
            Width = Math.Clamp(maxWidth, 80, 340),
            MinHeight = Math.Max(36, fontSize * 1.7),
            MaxHeight = 220,
            FontSize = fontSize,
            FontFamily = new FontFamily("Segoe UI"),
            Foreground = foreground,
            Background = new SolidColorBrush(darkInk
                ? System.Windows.Media.Color.FromArgb(235, 255, 255, 255)
                : System.Windows.Media.Color.FromArgb(220, 20, 26, 35)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(95, 180, 255)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(5, 2, 5, 2),
            TextWrapping = TextWrapping.Wrap,
            AcceptsReturn = true,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        Canvas.SetLeft(editor, point.X);
        Canvas.SetTop(editor, point.Y);
        Panel.SetZIndex(editor, 100);
        host.Children.Add(editor);

        var finished = false;
        void Finish(bool accept)
        {
            if (finished) return;
            finished = true;
            var value = editor.Text.Trim();
            host.Children.Remove(editor);
            if (accept && value.Length > 0) onAccept(value);
            onFinish();
        }

        editor.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { e.Handled = true; Finish(false); }
            else if (e.Key == Key.Return && Keyboard.Modifiers != ModifierKeys.Shift)
            { e.Handled = true; Finish(true); }
        };
        editor.LostKeyboardFocus += (_, _) => Finish(true);
        editor.Loaded += (_, _) => { editor.Focus(); Keyboard.Focus(editor); };
        return editor;
    }
}
