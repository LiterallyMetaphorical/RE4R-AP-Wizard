namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Turns a set of individually-selected names into the shortest equivalent list
/// for a YAML option, by replacing a fully-selected group with its group name.
/// </summary>
/// <remarks>
/// The picker works in individual names because that is what a tri-state row
/// needs to mean, but writing 28 key names when the player ticked "Key Items"
/// produces a YAML nobody can read or hand-edit afterwards. Archipelago expands
/// group names itself, so the collapsed form is exactly equivalent.
///
/// Shared by both front ends deliberately. The Windows and Linux pickers must
/// produce identical YAML for identical choices, and the only way to guarantee
/// that is for the rule to exist once.
/// </remarks>
public static class YamlSelectionCollapser
{
    /// <summary>
    /// Collapse <paramref name="selected"/> against <paramref name="groups"/>.
    /// </summary>
    /// <param name="selected">Individually selected member names.</param>
    /// <param name="groups">Group name to its full membership.</param>
    public static IReadOnlyList<string> Collapse(
        IEnumerable<string>? selected,
        IReadOnlyDictionary<string, List<string>>? groups)
    {
        var remaining = new HashSet<string>(
            (selected ?? Enumerable.Empty<string>())
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .Select(name => name.Trim()),
            StringComparer.Ordinal);

        if (remaining.Count == 0)
        {
            return Array.Empty<string>();
        }

        var result = new List<string>();

        if (groups is not null)
        {
            // Largest groups first: when one group's membership is a subset of
            // another's, collapsing to the bigger name is the shorter answer,
            // and taking them in size order makes the outcome deterministic
            // rather than dependent on dictionary ordering.
            var ordered = groups
                .Where(entry => entry.Value is { Count: > 0 })
                .OrderByDescending(entry => entry.Value.Count)
                .ThenBy(entry => entry.Key, StringComparer.Ordinal);

            foreach (var (groupName, members) in ordered)
            {
                // A group only collapses if EVERY member is selected. A
                // partially-selected group has to stay as individual names or
                // the YAML would silently widen the player's choice.
                if (members.All(member => remaining.Contains(member)))
                {
                    result.Add(groupName);
                    foreach (var member in members)
                    {
                        remaining.Remove(member);
                    }
                }
            }
        }

        result.AddRange(remaining);
        result.Sort(StringComparer.Ordinal);
        return result;
    }
}
