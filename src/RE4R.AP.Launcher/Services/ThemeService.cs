using System.Windows;

namespace RE4R.AP.Launcher.Services;

/// <summary>
/// Swaps the application's theme dictionary at runtime.
/// </summary>
/// <remarks>
/// The themes are two ResourceDictionaries carrying the same keys, so switching
/// is a matter of replacing whichever one is currently merged. Everything in the
/// markup references those keys with DynamicResource rather than StaticResource,
/// which is what lets the swap repaint a window that is already open instead of
/// needing a restart.
/// </remarks>
public static class ThemeService
{
    public const string Dark = "dark";
    public const string Light = "light";

    // Absolute pack URIs, not relative ones. A relative URI only resolves
    // against an ambient base, and when it fails it throws INSIDE Apply -
    // after the old dictionary has already been removed - leaving the app with
    // no palette at all. That paints a blank white window with invisible text
    // and a perfectly healthy control tree, which is a miserable thing to
    // diagnose. The pack form has no ambient dependency.
    private const string DarkSource = "pack://application:,,,/RE4R.AP.Launcher;component/Themes/Dark.xaml";
    private const string LightSource = "pack://application:,,,/RE4R.AP.Launcher;component/Themes/Light.xaml";

    /// <summary>The theme currently applied. Dark is the launcher's default.</summary>
    public static string Current { get; private set; } = Dark;

    public static string Normalize(string? theme) =>
        string.Equals(theme?.Trim(), Light, StringComparison.OrdinalIgnoreCase) ? Light : Dark;

    /// <summary>Apply a theme, replacing any theme dictionary already merged.</summary>
    public static void Apply(string? theme)
    {
        var resolved = Normalize(theme);
        var application = Application.Current;
        if (application is null)
        {
            // Still record the choice: a headless or very early call should not
            // lose the setting just because there is no window to repaint yet.
            Current = resolved;
            return;
        }

        var merged = application.Resources.MergedDictionaries;

        // Build and ADD first, remove second. If constructing the replacement
        // throws, the app keeps the palette it already had; the other order
        // leaves it with none, which paints a blank window with invisible text.
        var replacement = new ResourceDictionary
        {
            Source = new Uri(resolved == Light ? LightSource : DarkSource, UriKind.Absolute),
        };
        merged.Add(replacement);

        // Match on the file name: App.xaml authors its entry as a relative
        // "Themes/Dark.xaml" while this builds an absolute pack URI, so
        // comparing whole strings would never find the one to drop and both
        // would stay merged.
        for (var index = merged.Count - 2; index >= 0; index--)
        {
            var source = merged[index].Source?.OriginalString ?? string.Empty;
            if (source.EndsWith("Dark.xaml", StringComparison.OrdinalIgnoreCase)
                || source.EndsWith("Light.xaml", StringComparison.OrdinalIgnoreCase))
            {
                merged.RemoveAt(index);
            }
        }

        Current = resolved;
    }

    /// <summary>The theme that is not currently applied.</summary>
    public static string Other() => Current == Light ? Dark : Light;
}
