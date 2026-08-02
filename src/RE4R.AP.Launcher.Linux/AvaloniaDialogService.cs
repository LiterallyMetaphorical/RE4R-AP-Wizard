using System.Diagnostics;
using Avalonia.Controls;
using Avalonia.Input.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Services;

internal sealed class AvaloniaDialogService : IUiDialogService
{
    private readonly Window _owner;

    public AvaloniaDialogService(Window owner)
    {
        _owner = owner;
    }

    public async Task<string?> BrowseForFolderAsync(string? initialDirectory)
    {
        var folders = await _owner.StorageProvider.OpenFolderPickerAsync(
            new FolderPickerOpenOptions
            {
                Title = "Select folder",
                AllowMultiple = false,
                SuggestedStartLocation = await TryGetFolderAsync(initialDirectory),
            });
        return folders.FirstOrDefault()?.TryGetLocalPath();
    }

    public async Task<IReadOnlyList<string>> BrowseForFilesAsync(
        string title,
        string filter,
        bool multiSelect,
        string? initialDirectory = null)
    {
        var patterns = filter.Split('|')
            .Where((_, index) => index % 2 == 1)
            .SelectMany(value => value.Split(';'))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var files = await _owner.StorageProvider.OpenFilePickerAsync(
            new FilePickerOpenOptions
            {
                Title = title,
                AllowMultiple = multiSelect,
                SuggestedStartLocation = await TryGetFolderAsync(initialDirectory),
                FileTypeFilter =
                [
                    new FilePickerFileType("Supported files") { Patterns = patterns },
                ],
            });
        return files.Select(file => file.TryGetLocalPath())
            .Where(path => path is not null)
            .Select(path => path!)
            .ToArray();
    }

    public async Task<string?> BrowseForSaveFileAsync(string title, string filter, string defaultFileName)
    {
        var file = await _owner.StorageProvider.SaveFilePickerAsync(
            new FilePickerSaveOptions
            {
                Title = title,
                SuggestedFileName = defaultFileName,
                DefaultExtension = "yaml",
                FileTypeChoices =
                [
                    new FilePickerFileType("YAML") { Patterns = ["*.yaml", "*.yml"] },
                ],
            });
        return file?.TryGetLocalPath();
    }

    public Task ShowNotificationAsync(string title, string message) =>
        ShowMessageAsync(title, message, ["OK"]).ContinueWith(_ => { }, TaskScheduler.Default);

    public async Task<bool> ConfirmOverwriteDifferentSeedAsync(ExistingSessionConflictPrompt prompt)
    {
        var message =
            $"You have an unfinished session for {prompt.SlotName} on {prompt.NormalizedServer}.\n\n"
            + $"Existing seed: {prompt.ExistingSeedName}\nIncoming seed: {prompt.IncomingSeedName}\n\n"
            + "Patching the new seed overwrites the game files of the existing one. "
            + "You can always re-patch the old seed later to go back.";
        return await ShowMessageAsync(
            "Switch to the New Seed?",
            message,
            ["Overwrite and Patch New Seed", "Cancel"]) == "Overwrite and Patch New Seed";
    }

    public async Task<ResumeSessionDecision> ChooseResumeActionAsync(ResumeSessionPrompt prompt)
    {
        var result = await ShowMessageAsync(
            "Already Patched",
            $"Your game is already patched for this multiworld ({prompt.SlotName} on {prompt.NormalizedServer}).\n\n"
                + $"Seed: {prompt.SeedName}\nLast patched: {prompt.PatchedAtUtc?.ToLocalTime():yyyy-MM-dd HH:mm}\n\n"
                + "Keep Current World starts playing with the world exactly as it is.\n"
                + "Re-patch This Seed rebuilds the game files for this same seed - use it after "
                + "changing options, verifying game files, or when the world looks wrong.",
            ["Keep Current World", "Re-patch This Seed", "Cancel"]);
        return result switch
        {
            "Keep Current World" => ResumeSessionDecision.Resume,
            "Re-patch This Seed" => ResumeSessionDecision.RePatch,
            _ => ResumeSessionDecision.Cancel,
        };
    }

    public async Task<bool> ConfirmInstallAsync(InstallConfirmation confirmation)
    {
        var preview = string.Join(
            '\n',
            confirmation.Files.Take(12).Select(file => $"• {file.RelativePath}"));
        if (confirmation.Files.Count > 12)
        {
            preview += $"\n… and {confirmation.Files.Count - 12} more";
        }

        return await ShowMessageAsync(
            confirmation.OperationName,
            $"Destination: {confirmation.DestinationRootPath}\n"
                + $"{confirmation.TotalFileCount} file(s), {confirmation.TotalBytes / 1024d / 1024d:0.0} MB\n\n{preview}",
            ["Install", "Cancel"]) == "Install";
    }

    public async Task<bool> ConfirmProceedWithWarningAsync(
        string title,
        string message,
        string proceedLabel = "Proceed",
        string cancelLabel = "Cancel") =>
        await ShowMessageAsync(title, message, [proceedLabel, cancelLabel]) == proceedLabel;

    public async Task SetClipboardTextAsync(string text)
    {
        var clipboard = TopLevel.GetTopLevel(_owner)?.Clipboard
            ?? throw new InvalidOperationException("Clipboard is unavailable.");
        await clipboard.SetTextAsync(text);
    }

    public Task OpenFolderAsync(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("xdg-open", path) { UseShellExecute = false });
        return Task.CompletedTask;
    }

    public async Task InvokeOnUiThreadAsync(Func<Task> action, UiThreadPriority priority = UiThreadPriority.Normal)
    {
        if (Dispatcher.UIThread.CheckAccess())
        {
            await action();
            return;
        }

        var dispatcherPriority = priority == UiThreadPriority.Background
            ? DispatcherPriority.Background
            : DispatcherPriority.Normal;
        await Dispatcher.UIThread.InvokeAsync(action, dispatcherPriority);
    }

    private async Task<IStorageFolder?> TryGetFolderAsync(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
        {
            return null;
        }

        return await _owner.StorageProvider.TryGetFolderFromPathAsync(path);
    }

    private async Task<string> ShowMessageAsync(string title, string message, IReadOnlyList<string> choices)
    {
        var result = choices[^1];
        var dialog = new Window
        {
            Title = title,
            Width = 520,
            SizeToContent = SizeToContent.Height,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
        };
        var buttons = new StackPanel
        {
            Orientation = Avalonia.Layout.Orientation.Horizontal,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
            Spacing = 8,
        };
        foreach (var choice in choices)
        {
            var button = new Button { Content = choice, MinWidth = 90 };
            button.Click += (_, _) =>
            {
                result = choice;
                dialog.Close();
            };
            buttons.Children.Add(button);
        }

        dialog.Content = new StackPanel
        {
            Margin = new Avalonia.Thickness(24),
            Spacing = 18,
            Children =
            {
                new TextBlock { Text = message, TextWrapping = Avalonia.Media.TextWrapping.Wrap },
                buttons,
            },
        };
        await dialog.ShowDialog(_owner);
        return result;
    }
}
