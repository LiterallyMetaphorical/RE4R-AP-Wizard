using System.Globalization;
using System.Windows;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Views;

public partial class InstallConfirmationDialog : Window
{
    public InstallConfirmationDialog(InstallConfirmation confirmation)
    {
        InitializeComponent();

        ArgumentNullException.ThrowIfNull(confirmation);

        PromptTextBlock.Text = BuildPrompt(confirmation);
        SummaryTextBlock.Text =
            $"{confirmation.TotalFileCount} files, {FormatSize(confirmation.TotalBytes)} total." +
            Environment.NewLine +
            BuildWarning(confirmation) +
            " To remove the patch later, delete the installed re_chunk_000.pak.patch_XXX.pak file from the game folder" +
            " (Steam > Verify integrity restores any modified originals but leaves added files alone).";
        DestinationTextBlock.Text = $"Destination: {confirmation.DestinationRootPath}";
        BreakdownTextBlock.Text = BuildBreakdown(confirmation);
        FilesGrid.ItemsSource = confirmation.Files;
    }

    private static string BuildBreakdown(InstallConfirmation confirmation)
    {
        // Group by a meaningful path prefix (for game paks that is
        // natives/stm/<realm>, otherwise the first segment) so the player
        // sees "what kind of thing" instead of a thousand raw rows.
        static string GroupKey(string relativePath)
        {
            var segments = relativePath.Replace('\\', '/').Split('/');
            return segments.Length >= 3 && string.Equals(segments[0], "natives", StringComparison.OrdinalIgnoreCase)
                ? string.Join('/', segments[0], segments[1], segments[2])
                : segments[0];
        }

        var groups = confirmation.Files
            .GroupBy(file => GroupKey(file.RelativePath), StringComparer.OrdinalIgnoreCase)
            .Select(group => new
            {
                Prefix = group.Key,
                Count = group.Count(),
                Bytes = group.Sum(file => file.Size),
            })
            .OrderByDescending(group => group.Count)
            .ToList();

        var lines = groups
            .Take(8)
            .Select(group => $"{group.Prefix}/...  -  {group.Count} file(s), {FormatSize(group.Bytes)}")
            .ToList();
        if (groups.Count > 8)
        {
            var rest = groups.Skip(8).ToList();
            lines.Add($"... and {rest.Count} more group(s), {rest.Sum(group => group.Count)} file(s), {FormatSize(rest.Sum(group => group.Bytes))}");
        }

        return string.Join(Environment.NewLine, lines);
    }

    private static string BuildPrompt(InstallConfirmation confirmation)
    {
        return confirmation.OperationName.Contains("Patch", StringComparison.OrdinalIgnoreCase)
            ? $"This will patch your RE4R game files at {confirmation.DestinationRootPath}. Proceed?"
            : $"This will copy mod files to {confirmation.DestinationRootPath}. Proceed?";
    }

    private static string BuildWarning(InstallConfirmation confirmation)
    {
        return confirmation.OperationName.Contains("Patch", StringComparison.OrdinalIgnoreCase)
            ? "Warning: this will overwrite files in your RE4R install."
            : "Warning: this will overwrite REFramework mod files in your RE4R install.";
    }

    private static string FormatSize(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB"];
        var value = Math.Abs((double)bytes);
        var unitIndex = 0;
        while (value >= 1024 && unitIndex < units.Length - 1)
        {
            value /= 1024;
            unitIndex++;
        }

        return string.Format(CultureInfo.InvariantCulture, "{0:0.##} {1}", value, units[unitIndex]);
    }

    private void ProceedButton_OnClick(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
        Close();
    }

    private void CancelButton_OnClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
