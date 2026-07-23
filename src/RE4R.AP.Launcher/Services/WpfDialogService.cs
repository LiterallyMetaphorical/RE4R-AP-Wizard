using System.IO;
using Microsoft.Win32;
using System.Windows;
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
            "Starting a new seed will overwrite your patched game files. Proceed?";

        var result = MessageBox.Show(
            _owner,
            message,
            "Overwrite Existing Session?",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        return Task.FromResult(result == MessageBoxResult.Yes);
    }

    public Task<ResumeSessionDecision> ChooseResumeActionAsync(ResumeSessionPrompt prompt)
    {
        var message =
            $"A patched session already exists for {prompt.SlotName} on {prompt.NormalizedServer}." +
            Environment.NewLine + Environment.NewLine +
            $"Seed: {prompt.SeedName}" + Environment.NewLine +
            $"Last patched: {FormatTimestamp(prompt.PatchedAtUtc)}" + Environment.NewLine + Environment.NewLine +
            "Choose Yes to Resume, No to Re-patch, or Cancel to stop.";

        var result = MessageBox.Show(
            _owner,
            message,
            "Resume or Re-patch?",
            MessageBoxButton.YesNoCancel,
            MessageBoxImage.Question);

        return Task.FromResult(
            result switch
            {
                MessageBoxResult.Yes => ResumeSessionDecision.Resume,
                MessageBoxResult.No => ResumeSessionDecision.RePatch,
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

    public Task<bool> ConfirmProceedWithWarningAsync(string title, string message)
    {
        var result = MessageBox.Show(
            _owner,
            message,
            title,
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        return Task.FromResult(result == MessageBoxResult.Yes);
    }

    private static string FormatTimestamp(DateTimeOffset? timestamp)
    {
        return timestamp?.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") ?? "Unknown";
    }
}
