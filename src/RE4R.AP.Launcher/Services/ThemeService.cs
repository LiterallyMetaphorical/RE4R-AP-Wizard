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

    private const string DarkSource = "Themes/Dark.xaml";
    private const string LightSource = "Themes/Light.xaml";

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
        var replacement = new ResourceDictionary
        {
            Source = new Uri(resolved == Light ? LightSource : DarkSource, UriKind.Relative),
        };

        // Drop the previous theme before adding the new one. Leaving both merged
        // would let the older dictionary keep answering for keys the new one
        // happens not to override, which is how a half-switched window happens.
        for (var index = merged.Count - 1; index >= 0; index--)
        {
            var source = merged[index].Source?.OriginalString ?? string.Empty;
            if (source.EndsWith(DarkSource, StringComparison.OrdinalIgnoreCase)
                || source.EndsWith(LightSource, StringComparison.OrdinalIgnoreCase))
            {
                merged.RemoveAt(index);
            }
        }

        merged.Add(replacement);
        Current = resolved;
    }

    /// <summary>The theme that is not currently applied.</summary>
    public static string Other() => Current == Light ? Dark : Light;
}
