using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Services;

/// <summary>
/// Priority for work marshaled onto the UI thread. Background keeps the work
/// below user input, so a busy render path (the batched workflow-log flush)
/// cannot starve the buttons. The log-flush timer depends on this: it was a
/// Background-priority DispatcherTimer specifically to keep Proceed/Cancel
/// responsive under heavy generation output.
/// </summary>
public enum UiThreadPriority
{
    Normal,
    Background,
}

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

    Task SetClipboardTextAsync(string text);

    Task OpenFolderAsync(string path);

    Task InvokeOnUiThreadAsync(Func<Task> action, UiThreadPriority priority = UiThreadPriority.Normal);
}
