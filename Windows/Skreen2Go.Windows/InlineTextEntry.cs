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

internal sealed class InlineTextEntry
{
    private readonly Canvas host;
    private readonly Action<string> onAccept;
    private readonly Action onFinish;
    private bool finished;

    public TextBox Editor { get; }

    private InlineTextEntry(Canvas host, TextBox editor, Action<string> onAccept,
        Action onFinish)
    {
        this.host = host;
        Editor = editor;
        this.onAccept = onAccept;
        this.onFinish = onFinish;
    }

    public static InlineTextEntry Show(Canvas host, Point point, double fontSize, Brush foreground,
        double maxWidth, Action<string> onAccept, Action onFinish,
        string initialText = "", Point? caretPoint = null)
    {
        var ink = (foreground as SolidColorBrush)?.Color ?? Colors.White;
        var darkInk = ink.R * .2126 + ink.G * .7152 + ink.B * .0722 < 80;
        var editor = new TextBox
        {
            Width = Math.Max(1, maxWidth),
            MinHeight = Math.Max(36, fontSize * 1.7),
            MaxHeight = Math.Max(36, host.ActualHeight - point.Y),
            FontSize = fontSize,
            FontFamily = new FontFamily("Segoe UI"),
            Foreground = foreground,
            Background = new SolidColorBrush(darkInk
                ? System.Windows.Media.Color.FromArgb(255, 255, 255, 255)
                : System.Windows.Media.Color.FromArgb(255, 20, 26, 35)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(95, 180, 255)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(5, 2, 5, 2),
            TextWrapping = TextWrapping.Wrap,
            AcceptsReturn = true,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Text = initialText
        };
        Canvas.SetLeft(editor, point.X);
        Canvas.SetTop(editor, point.Y);
        Panel.SetZIndex(editor, 100);
        host.Children.Add(editor);
        var entry = new InlineTextEntry(host, editor, onAccept, onFinish);

        editor.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { e.Handled = true; entry.Cancel(); }
            else if (e.Key == Key.Return && Keyboard.Modifiers != ModifierKeys.Shift)
            { e.Handled = true; entry.Commit(); }
        };
        editor.LostKeyboardFocus += (_, _) => entry.Commit();
        editor.Loaded += (_, _) =>
        {
            editor.Focus();
            Keyboard.Focus(editor);
            editor.CaretIndex = caretPoint is { } location
                ? Math.Max(0, editor.GetCharacterIndexFromPoint(location, true))
                : editor.Text.Length;
        };
        return entry;
    }

    public bool Contains(DependencyObject source)
    {
        for (DependencyObject? current = source; current is not null;
            current = VisualTreeHelper.GetParent(current))
            if (ReferenceEquals(current, Editor)) return true;
        return false;
    }

    public void Commit() => Finish(true);
    public void Cancel() => Finish(false);

    private void Finish(bool accept)
    {
        if (finished) return;
        finished = true;
        var value = Editor.Text.Trim();
        host.Children.Remove(Editor);
        if (accept && value.Length > 0) onAccept(value);
        onFinish();
    }
}
