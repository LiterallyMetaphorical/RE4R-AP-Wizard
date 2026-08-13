using System.Collections.ObjectModel;
using System.ComponentModel;
using RE4R.AP.Launcher.Core.Services;
using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.Models;

/// <summary>
/// One picker: groups up front, individual names behind a search box, each row
/// set to Default or one of two opposite stances.
/// </summary>
/// <remarks>
/// <para>
/// Used twice - once for items (local_items / non_local_items) and once for
/// locations (exclude_locations / priority_locations) - because each pair is
/// two directions on the same list rather than two independent settings.
/// Modelling it that way halves the surface and makes a contradiction
/// impossible to express, instead of something we would have to validate and
/// explain.
/// </para>
/// <para>
/// Only groups show until the player types. 127 items and 460 locations are
/// far too many to scroll, and the groups cover essentially every real request
/// ("all my key items elsewhere" is the reported one). The search is there so
/// precision is possible, not so it is required.
/// </para>
/// <para>
/// Lives in the shared Models folder on purpose: the Linux project compiles
/// these sources by wildcard, so both front ends get identical behaviour and
/// only the view construction differs.
/// </para>
/// </remarks>
public sealed class YamlSelectionListViewModel : ObservableObject
{
    private readonly List<YamlSelectionEntryViewModel> _groups = new();
    private readonly List<YamlSelectionEntryViewModel> _individuals = new();
    private readonly Dictionary<string, List<string>> _groupMembers;
    private bool _suppressPropagation;
    private string _searchText = string.Empty;
    private string _summaryText = string.Empty;

    public YamlSelectionListViewModel(
        string title,
        string firstStanceLabel,
        string secondStanceLabel,
        string searchHint,
        IReadOnlyDictionary<string, List<string>> groups,
        IEnumerable<string> allNames)
    {
        Title = title;
        FirstStanceLabel = firstStanceLabel;
        SecondStanceLabel = secondStanceLabel;
        SearchHint = searchHint;
        StanceOptions = new[] { "Default", firstStanceLabel, secondStanceLabel };
        _groupMembers = groups.ToDictionary(
            entry => entry.Key,
            entry => entry.Value.ToList(),
            StringComparer.Ordinal);

        foreach (var (groupName, members) in _groupMembers.OrderBy(e => e.Key, StringComparer.Ordinal))
        {
            var entry = new YamlSelectionEntryViewModel
            {
                DisplayName = groupName,
                IsGroup = true,
                Members = members,
            };
            entry.PropertyChanged += OnEntryPropertyChanged;
            _groups.Add(entry);
        }

        foreach (var name in allNames.Distinct(StringComparer.Ordinal).OrderBy(n => n, StringComparer.Ordinal))
        {
            var entry = new YamlSelectionEntryViewModel { DisplayName = name };
            entry.PropertyChanged += OnEntryPropertyChanged;
            _individuals.Add(entry);
        }

        RefreshVisible();
        RefreshSummary();
    }

    public string Title { get; }

    public string FirstStanceLabel { get; }

    public string SecondStanceLabel { get; }

    public string SearchHint { get; }

    /// <summary>The three combo entries, in stance order.</summary>
    public IReadOnlyList<string> StanceOptions { get; }

    /// <summary>Groups always; individuals only while a search is active.</summary>
    public ObservableCollection<YamlSelectionEntryViewModel> VisibleEntries { get; } = new();

    public string SearchText
    {
        get => _searchText;
        set
        {
            if (SetProperty(ref _searchText, value ?? string.Empty))
            {
                RefreshVisible();
            }
        }
    }

    public string SummaryText
    {
        get => _summaryText;
        private set => SetProperty(ref _summaryText, value);
    }

    /// <summary>Names at stance 1, collapsed to group names where a group is whole.</summary>
    public IReadOnlyList<string> BuildFirstList() => Build(YamlSelectionEntryViewModel.StanceFirst);

    /// <summary>Names at stance 2, collapsed to group names where a group is whole.</summary>
    public IReadOnlyList<string> BuildSecondList() => Build(YamlSelectionEntryViewModel.StanceSecond);

    /// <summary>Restore a saved draft. Group rows follow from their members.</summary>
    public void ApplySelection(IEnumerable<string>? first, IEnumerable<string>? second)
    {
        _suppressPropagation = true;
        try
        {
            foreach (var entry in _individuals)
            {
                entry.Stance = YamlSelectionEntryViewModel.StanceDefault;
            }

            Stamp(first, YamlSelectionEntryViewModel.StanceFirst);
            Stamp(second, YamlSelectionEntryViewModel.StanceSecond);
            RecomputeGroupStances();
        }
        finally
        {
            _suppressPropagation = false;
        }

        RefreshSummary();
    }

    private void Stamp(IEnumerable<string>? names, int stance)
    {
        if (names is null)
        {
            return;
        }

        // A saved list may name a group or an individual; expand groups back
        // out so the rows are the single source of truth from here on.
        var wanted = new HashSet<string>(StringComparer.Ordinal);
        foreach (var name in names.Where(n => !string.IsNullOrWhiteSpace(n)).Select(n => n.Trim()))
        {
            if (_groupMembers.TryGetValue(name, out var members))
            {
                foreach (var member in members)
                {
                    wanted.Add(member);
                }
            }
            else
            {
                wanted.Add(name);
            }
        }

        foreach (var entry in _individuals.Where(e => wanted.Contains(e.DisplayName)))
        {
            entry.Stance = stance;
        }
    }

    private IReadOnlyList<string> Build(int stance)
    {
        var selected = _individuals
            .Where(entry => entry.Stance == stance)
            .Select(entry => entry.DisplayName);
        return YamlSelectionCollapser.Collapse(selected, _groupMembers);
    }

    private void OnEntryPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!string.Equals(e.PropertyName, nameof(YamlSelectionEntryViewModel.Stance), StringComparison.Ordinal))
        {
            return;
        }

        if (_suppressPropagation || sender is not YamlSelectionEntryViewModel entry)
        {
            return;
        }

        _suppressPropagation = true;
        try
        {
            if (entry.IsGroup)
            {
                // Setting a group stamps every member. Individuals can then be
                // adjusted afterwards, and the group row follows them back.
                var members = new HashSet<string>(entry.Members, StringComparer.Ordinal);
                foreach (var individual in _individuals.Where(i => members.Contains(i.DisplayName)))
                {
                    individual.Stance = entry.Stance;
                }
            }
            else
            {
                RecomputeGroupStances();
            }
        }
        finally
        {
            _suppressPropagation = false;
        }

        RefreshSummary();
        SelectionChanged?.Invoke();
    }

    /// <summary>
    /// A group shows a stance only when every member agrees; a part-selected
    /// group reads Default so the row never claims more than is true.
    /// </summary>
    private void RecomputeGroupStances()
    {
        var byName = _individuals.ToDictionary(e => e.DisplayName, StringComparer.Ordinal);
        foreach (var group in _groups)
        {
            var stance = YamlSelectionEntryViewModel.StanceDefault;
            var first = true;
            foreach (var member in group.Members)
            {
                if (!byName.TryGetValue(member, out var entry))
                {
                    continue;
                }

                if (first)
                {
                    stance = entry.Stance;
                    first = false;
                }
                else if (entry.Stance != stance)
                {
                    stance = YamlSelectionEntryViewModel.StanceDefault;
                    break;
                }
            }

            group.Stance = stance;
        }
    }

    private void RefreshVisible()
    {
        VisibleEntries.Clear();
        foreach (var group in _groups)
        {
            VisibleEntries.Add(group);
        }

        var search = _searchText.Trim();
        if (search.Length == 0)
        {
            return;
        }

        foreach (var entry in _individuals
                     .Where(e => e.DisplayName.Contains(search, StringComparison.OrdinalIgnoreCase))
                     .Take(MaxSearchResults))
        {
            VisibleEntries.Add(entry);
        }
    }

    private void RefreshSummary()
    {
        var first = _individuals.Count(e => e.Stance == YamlSelectionEntryViewModel.StanceFirst);
        var second = _individuals.Count(e => e.Stance == YamlSelectionEntryViewModel.StanceSecond);
        SummaryText = first == 0 && second == 0
            ? "Nothing changed from the default."
            : $"{first} {FirstStanceLabel.ToLowerInvariant()}, {second} {SecondStanceLabel.ToLowerInvariant()}.";
    }

    /// <summary>Raised when any row's stance changes, so the YAML preview can refresh.</summary>
    public event Action? SelectionChanged;

    // A search that matches hundreds of names is not a useful list to scroll,
    // and rebuilding that many rows on every keystroke is what makes a picker
    // feel broken. Narrow the search instead.
    private const int MaxSearchResults = 60;
}
