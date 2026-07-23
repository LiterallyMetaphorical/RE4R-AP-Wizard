using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Services;

public interface IUiDialogService
{
    Task<string?> BrowseForFolderAsync(string? initialDirectory);

    Task<IReadOnlyList<string>> BrowseForFilesAsync(string title, string filter, bool multiSelect, string? initialDirectory = null);

    Task<string?> BrowseForSaveFileAsync(string title, string filter, string defaultFileName);

    Task ShowNotificationAsync(string title, string message);

    Task<bool> ConfirmOverwriteDifferentSeedAsync(ExistingSessionConflictPrompt prompt);

    Task<ResumeSessionDecision> ChooseResumeActionAsync(ResumeSessionPrompt prompt);

    Task<bool> ConfirmInstallAsync(InstallConfirmation confirmation);

    Task<bool> ConfirmProceedWithWarningAsync(string title, string message);
}
