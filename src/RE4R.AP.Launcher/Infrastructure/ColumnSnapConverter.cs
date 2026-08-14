using System.Globalization;
using System.Windows.Data;

namespace RE4R.AP.Launcher.Infrastructure;

/// <summary>
/// Rounds an available width down to a whole number of option-card columns.
/// </summary>
/// <remarks>
/// <para>
/// Bound to a settings wrap panel's MaxWidth, this is what makes the page pick
/// its own column count: two on a normal window, three once there is genuinely
/// room, without ever leaving a ragged part-column of dead space on the right.
/// </para>
/// <para>
/// A plain uncapped WrapPanel would also reflow, but it would centre the slack
/// inside a half-column gap and the full-width rows would stop lining up with
/// the grid above them. Snapping to the pitch keeps every row the same width.
/// </para>
/// <para>
/// ConverterParameter is the card pitch (card width plus its right margin).
/// The column count is clamped: at least one, so a very narrow window still
/// shows a card, and at most <see cref="MaxColumns"/>, because settings text
/// stops being readable long before the columns stop fitting.
/// </para>
/// </remarks>
public sealed class ColumnSnapConverter : IValueConverter
{
    public const int MaxColumns = 3;

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not double available || double.IsNaN(available) || available <= 0)
        {
            return double.PositiveInfinity;
        }

        var pitch = 550d;
        if (parameter is string raw && double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) && parsed > 0)
        {
            pitch = parsed;
        }

        var columns = (int)Math.Floor(available / pitch);
        columns = Math.Clamp(columns, 1, MaxColumns);
        return columns * pitch;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
