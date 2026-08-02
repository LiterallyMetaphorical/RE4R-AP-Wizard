using System.Diagnostics;
using System.IO;
using Microsoft.Win32;
using System.Windows;
using System.Windows.Threading;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Views;

namespace RE4R.AP.Launcher.Services;

public sealed class WpfDialogService : IUiDialogService
{
    private readonly Window _owner;

    public WpfDialogService(Window owner)
    {
        _owner = owner ?? throw new ArgumentNullException(nameof(owner));
    }

    public Task<string?> BrowseForFolderAsync(string? initialDirectory)
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Select your Resident Evil 4 Remake install folder",
        };

        if (!string.IsNullOrWhiteSpace(initialDirectory) && Directory.Exists(initialDirectory))
        {
            dialog.InitialDirectory = initialDirectory;
            dialog.FolderName = initialDirectory;
        }

        var result = dialog.ShowDialog(_owner);
        return Task.FromResult(result == true ? dialog.FolderName : null);
    }

    public Task<IReadOnlyList<string>> BrowseForFilesAsync(string title, string filter, bool multiSelect, string? initialDirectory = null)
    {
        var dialog = new OpenFileDialog
        {
            Title = title,
            Filter = filter,
            Multiselect = multiSelect,
        };

        if (!string.IsNullOrWhiteSpace(initialDirectory) && Directory.Exists(initialDirectory))
        {
            dialog.InitialDirectory = initialDirectory;
        }

        var result = dialog.ShowDialog(_owner);
        IReadOnlyList<string> fileNames = result == true
            ? dialog.FileNames
            : Array.Empty<string>();
        return Task.FromResult(fileNames);
    }

    public Task<string?> BrowseForSaveFileAsync(string title, string filter, string defaultFileName)
    {
        var dialog = new SaveFileDialog
        {
            Title = title,
            Filter = filter,
            FileName = defaultFileName,
            AddExtension = true,
            DefaultExt = ".yaml",
        };

        var result = dialog.ShowDialog(_owner);
        return Task.FromResult(result == true ? dialog.FileName : null);
    }

    public Task ShowNotificationAsync(string title, string message)
    {
        MessageBox.Show(
            _owner,
            message,
            title,
            MessageBoxButton.OK,
            MessageBoxImage.Information);
        return Task.CompletedTask;
    }

    public Task<bool> ConfirmOverwriteDifferentSeedAsync(ExistingSessionConflictPrompt prompt)
    {
        var message =
            $"You have an unfinished session for {prompt.SlotName} on {prompt.NormalizedServer}." +
            Environment.NewLine + Environment.NewLine +
            $"Existing seed: {prompt.ExistingSeedName}" + Environment.NewLine +
            $"Incoming seed: {prompt.IncomingSeedName}" + Environment.NewLine + Environment.NewLine +
            "Patching the new seed overwrites the game files of the existing one. " +
            "You can always re-patch the old seed later to go back.";

        var chosen = ChoiceDialog.Show(
            _owner,
            "Switch to the New Seed?",
            message,
            ["Overwrite and Patch New Seed", "Cancel"]);

        return Task.FromResult(chosen == 0);
    }

    public Task<ResumeSessionDecision> ChooseResumeActionAsync(ResumeSessionPrompt prompt)
    {
        var message =
            $"Your game is already patched for this multiworld ({prompt.SlotName} on {prompt.NormalizedServer})." +
            Environment.NewLine + Environment.NewLine +
            $"Seed: {prompt.SeedName}" + Environment.NewLine +
            $"Last patched: {FormatTimestamp(prompt.PatchedAtUtc)}" + Environment.NewLine + Environment.NewLine +
            "Keep Current World starts playing with the world exactly as it is." + Environment.NewLine +
            "Re-patch This Seed rebuilds the game files for this same seed - use it after " +
            "changing options, verifying game files in Steam, or when the world looks wrong.";

        var chosen = ChoiceDialog.Show(
            _owner,
            "Already Patched",
            message,
            ["Keep Current World", "Re-patch This Seed", "Cancel"]);

        return Task.FromResult(
            chosen switch
            {
                0 => ResumeSessionDecision.Resume,
                1 => ResumeSessionDecision.RePatch,
                _ => ResumeSessionDecision.Cancel,
            });
    }

    public Task<bool> ConfirmInstallAsync(InstallConfirmation confirmation)
    {
        var dialog = new InstallConfirmationDialog(confirmation)
        {
            Owner = _owner,
        };

        var result = dialog.ShowDialog();
        return Task.FromResult(result == true);
    }

    public Task<bool> ConfirmProceedWithWarningAsync(
        string title,
        string message,
        string proceedLabel = "Proceed",
        string cancelLabel = "Cancel")
    {
        var chosen = ChoiceDialog.Show(_owner, title, message, [proceedLabel, cancelLabel]);
        return Task.FromResult(chosen == 0);
    }

    public Task SetClipboardTextAsync(string text)
    {
        Clipboard.SetText(text);
        return Task.CompletedTask;
    }

    public Task OpenFolderAsync(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        return Task.CompletedTask;
    }

    public async Task InvokeOnUiThreadAsync(Func<Task> action, UiThreadPriority priority = UiThreadPriority.Normal)
    {
        if (_owner.Dispatcher.CheckAccess())
        {
            await action();
            return;
        }

        var dispatcherPriority = priority == UiThreadPriority.Background
            ? DispatcherPriority.Background
            : DispatcherPriority.Normal;
        await await _owner.Dispatcher.InvokeAsync(action, dispatcherPriority);
    }

    private static string FormatTimestamp(DateTimeOffset? timestamp)
    {
        return timestamp?.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") ?? "Unknown";
    }
}
