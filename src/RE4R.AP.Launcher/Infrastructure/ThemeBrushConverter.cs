using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace RE4R.AP.Launcher.Infrastructure;

/// <summary>
/// Resolves a theme resource key from a view model into the current theme's brush.
/// </summary>
/// <remarks>
/// The shared view models describe a surface as "warning" or "success" by naming
/// a resource key, never a colour, so the same view model can drive the Windows
/// light and dark themes and the Linux front end. This converter is the Windows
/// half of that: key in, brush out.
///
/// A converter result does not re-evaluate on its own when the theme changes, so
/// <see cref="Services.ThemeService"/> raises an event that MainWindow turns into
/// a property-changed nudge on the affected view models. Without that the banner
/// and status chips would keep their old colours until their state next changed.
/// </remarks>
public sealed class ThemeBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string key || string.IsNullOrWhiteSpace(key))
        {
            return DependencyProperty.UnsetValue;
        }

        if (Application.Current?.TryFindResource(key) is Brush brush)
        {
            return brush;
        }

        // A key that is not in the dictionaries is a bug, but painting nothing is
        // better than throwing inside a binding: UnsetValue leaves whatever the
        // control would otherwise have used.
        return DependencyProperty.UnsetValue;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
