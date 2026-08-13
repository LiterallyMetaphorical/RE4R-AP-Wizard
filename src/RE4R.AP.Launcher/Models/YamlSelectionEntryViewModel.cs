using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.Models;

/// <summary>
/// One row in an item or location picker: a group, or a single name.
/// </summary>
/// <remarks>
/// <para>
/// Stance is 0/1/2 rather than an enum because both front ends bind it to a
/// three-item combo's SelectedIndex, and an int needs no converter on either
/// toolkit. What 1 and 2 mean is the list's business, not the row's: for items
/// they are "keep in my world" and "send to another world", for locations
/// "never anything important" and "always something important".
/// </para>
/// <para>
/// The two stances of a pair are opposite ends of ONE setting, which is the
/// whole reason this is a stance and not two checkboxes. A name cannot be in
/// local_items and non_local_items at once, so the UI should not be able to
/// say that it is.
/// </para>
/// </remarks>
public sealed class YamlSelectionEntryViewModel : ObservableObject
{
    public const int StanceDefault = 0;
    public const int StanceFirst = 1;
    public const int StanceSecond = 2;

    private int _stance;

    public string DisplayName { get; init; } = string.Empty;

    /// <summary>True for a group row; <see cref="Members"/> is then populated.</summary>
    public bool IsGroup { get; init; }

    /// <summary>Member names, for a group row. Empty for an individual.</summary>
    public IReadOnlyList<string> Members { get; init; } = Array.Empty<string>();

    public int Stance
    {
        get => _stance;
        set => SetProperty(ref _stance, Math.Clamp(value, StanceDefault, StanceSecond));
    }
}
