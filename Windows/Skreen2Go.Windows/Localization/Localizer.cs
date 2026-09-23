using System.Globalization;
using System.Windows;
using Skreen2Go.Windows.Core;

namespace Skreen2Go.Windows;

internal static class Localizer
{
    private static ResourceDictionary? active;

    public static void Apply(InterfaceLanguage language)
    {
        var russian = language == InterfaceLanguage.Russian ||
            language == InterfaceLanguage.System &&
            CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru";
        var dictionary = new ResourceDictionary
        {
            Source = new Uri($"Localization/Strings.{(russian ? "ru" : "en")}.xaml",
                UriKind.Relative)
        };
        var resources = System.Windows.Application.Current.Resources.MergedDictionaries;
        if (active is not null) resources.Remove(active);
        resources.Add(dictionary);
        active = dictionary;
    }

    public static string Get(string key) =>
        System.Windows.Application.Current.TryFindResource(key) as string ?? key;
}
