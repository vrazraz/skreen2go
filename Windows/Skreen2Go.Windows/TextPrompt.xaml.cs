using System.Windows;

namespace Skreen2Go.Windows;

public partial class TextPrompt : Window
{
    public string Value => Input.Text;

    public TextPrompt()
    {
        InitializeComponent();
        Loaded += (_, _) => Input.Focus();
    }

    private void OnAdd(object sender, RoutedEventArgs e) => DialogResult = true;
    private void OnCancel(object sender, RoutedEventArgs e) => DialogResult = false;
}
