using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Utilities;
using System.Globalization;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class LuaInstallService
{
    public LuaInstallService(
        string? assetsLuaDirectoryPath = null,
        string? assetsNativeDirectoryPath = null)
    {
        AssetsLuaDirectoryPath = assetsLuaDirectoryPath
            ?? Path.Combine(AppContext.BaseDirectory, "assets", "Lua");
        AssetsNativeDirectoryPath = assetsNativeDirectoryPath
            ?? Path.Combine(AppContext.BaseDirectory, "assets", "native");
    }

    public string AssetsLuaDirectoryPath { get; }

    public string AssetsNativeDirectoryPath { get; }

    public event Action<string>? LogMessage;

    public async Task<InstallResult> InstallPatchFilesAsync(
        BioRandGenerationResult generationResult,
        string re4rInstallPath,
        Func<InstallConfirmation, Task<bool>> confirmAsync,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(generationResult);
        ArgumentNullException.ThrowIfNull(confirmAsync);

        if (!generationResult.Success)
        {
            throw new InstallException("Patch install could not start because BioRand generation did not complete successfully.");
        }

        if (string.IsNullOrWhiteSpace(re4rInstallPath))
        {
            throw new InstallException("Patch install could not start because the RE4R install path is missing.");
        }

        var plannedFiles = generationResult.StagedFiles
            .Select(entry => BuildPatchPlannedFile(generationResult.StagingDirectoryPath, re4rInstallPath, entry))
            .ToList();

        return await InstallFilesAsync(
            operationName: "BioRand Patch Install",
            destinationRootPath: re4rInstallPath,
            plannedFiles,
            confirmAsync,
            cancellationToken);
    }

    public async Task<InstallResult> InstallLuaModFilesAsync(
        string re4rInstallPath,
        Func<InstallConfirmation, Task<bool>> confirmAsync,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(confirmAsync);

        if (string.IsNullOrWhiteSpace(re4rInstallPath))
        {
            throw new InstallException("Lua mod install could not start because the RE4R install path is missing.");
        }

        var plannedFiles = await BuildLuaPlannedFilesAsync(re4rInstallPath, cancellationToken);
        return await InstallFilesAsync(
            operationName: "Lua Mod Install",
            destinationRootPath: re4rInstallPath,
            plannedFiles,
            confirmAsync,
            cancellationToken);
    }

    private async Task<InstallResult> InstallFilesAsync(
        string operationName,
        string destinationRootPath,
        IReadOnlyList<InstallPlannedFile> plannedFiles,
        Func<InstallConfirmation, Task<bool>> confirmAsync,
        CancellationToken cancellationToken)
    {
        var confirmation = new InstallConfirmation
        {
            OperationName = operationName,
            DestinationRootPath = destinationRootPath,
            TotalFileCount = plannedFiles.Count,
            TotalBytes = plannedFiles.Sum(file => file.Size),
            Files = plannedFiles,
        };

        Log($"Preparing {operationName} for {plannedFiles.Count} files to {destinationRootPath} ({FormatSize(confirmation.TotalBytes)} total).");
        Log($"Showing {operationName} confirmation dialog for {plannedFiles.Count} files.");
        var confirmed = await confirmAsync(confirmation);
        if (!confirmed)
        {
            Log($"{operationName} confirmation was cancelled. No files were copied.");
            return new InstallResult
            {
                Success = false,
                Cancelled = true,
                FilesCopiedCount = 0,
            };
        }

        Log($"{operationName} was confirmed. Copying files now.");

        var copiedCount = 0;
        var verificationFailures = new List<InstallVerificationFailure>();

        foreach (var file in plannedFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var destinationDirectory = Path.GetDirectoryName(file.DestinationPath);
            if (string.IsNullOrWhiteSpace(destinationDirectory))
            {
                throw new InstallException($"Could not determine destination directory for {file.RelativePath}.");
            }

            Directory.CreateDirectory(destinationDirectory);
            Log($"Copying {file.RelativePath} to {file.DestinationPath}");

            try
            {
                File.Copy(file.SourcePath, file.DestinationPath, overwrite: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                throw new InstallException(
                    $"The launcher failed to copy {file.RelativePath} into your RE4R install at {file.DestinationPath}.",
                    ex);
            }

            copiedCount++;

            var actualHash = await HashingUtilities.ComputeSha256HexAsync(file.DestinationPath, cancellationToken);
            if (!string.Equals(actualHash, file.ExpectedSha256, StringComparison.OrdinalIgnoreCase))
            {
                verificationFailures.Add(
                    new InstallVerificationFailure
                    {
                        RelativePath = file.RelativePath,
                        ExpectedSha256 = file.ExpectedSha256,
                        ActualSha256 = actualHash,
                        Message = $"SHA256 mismatch for {file.RelativePath}.",
                    });
                Log($"Verification failed for {file.RelativePath}. The copied file hash did not match the source file.");
            }
            else
            {
                Log($"Verified {file.RelativePath}");
            }
        }

        if (verificationFailures.Count > 0)
        {
            Log($"{operationName} completed with {verificationFailures.Count} verification failure(s). The install should be treated as incomplete.");
            return new InstallResult
            {
                Success = false,
                Cancelled = false,
                FilesCopiedCount = copiedCount,
                VerificationFailures = verificationFailures,
            };
        }

        Log($"{operationName} complete. {copiedCount} files were copied and verified.");
        return new InstallResult
        {
            Success = true,
            Cancelled = false,
            FilesCopiedCount = copiedCount,
            VerificationFailures = Array.Empty<InstallVerificationFailure>(),
        };
    }

    private InstallPlannedFile BuildPatchPlannedFile(
        string stagingDirectoryPath,
        string re4rInstallPath,
        StagedFileEntry entry)
    {
        if (string.IsNullOrWhiteSpace(stagingDirectoryPath) || !Directory.Exists(stagingDirectoryPath))
        {
            throw new InstallException($"Patch install could not continue because the BioRand staging directory was not found at {stagingDirectoryPath}.");
        }

        if (string.IsNullOrWhiteSpace(entry.RelativePath))
        {
            throw new InstallException("Patch install could not continue because one staged BioRand file did not include a relative path.");
        }

        var normalizedRelativePath = entry.RelativePath.Replace('/', Path.DirectorySeparatorChar);
        var sourcePath = Path.Combine(stagingDirectoryPath, normalizedRelativePath);
        if (!File.Exists(sourcePath))
        {
            throw new InstallException($"Patch install could not continue because the staged BioRand file {sourcePath} was missing.");
        }

        return new InstallPlannedFile
        {
            RelativePath = entry.RelativePath.Replace('\\', '/'),
            SourcePath = sourcePath,
            DestinationPath = Path.Combine(re4rInstallPath, normalizedRelativePath),
            Size = entry.Size,
            ExpectedSha256 = entry.Sha256,
        };
    }

    private async Task<IReadOnlyList<InstallPlannedFile>> BuildLuaPlannedFilesAsync(
        string re4rInstallPath,
        CancellationToken cancellationToken)
    {
        var rootScriptSource = Path.Combine(AssetsLuaDirectoryPath, "ArchipelagoRE4R.lua");
        var moduleDirectorySource = Path.Combine(AssetsLuaDirectoryPath, "ArchipelagoRE4R");
        var dataDirectorySource = Path.Combine(AssetsLuaDirectoryPath, "data", "ArchipelagoRE4R");

        if (!File.Exists(rootScriptSource))
        {
            throw new InstallException($"Lua mod install could not continue because the bundled launcher root script was not found at {rootScriptSource}.");
        }

        if (!Directory.Exists(moduleDirectorySource))
        {
            throw new InstallException($"Lua mod install could not continue because the bundled launcher Lua directory was not found at {moduleDirectorySource}.");
        }

        if (!Directory.Exists(dataDirectorySource))
        {
            throw new InstallException($"Lua mod install could not continue because the bundled launcher Lua data directory was not found at {dataDirectorySource}.");
        }

        var plannedFiles = new List<InstallPlannedFile>();

        plannedFiles.Add(
            await BuildLuaPlannedFileAsync(
                rootScriptSource,
                relativePath: "reframework/autorun/ArchipelagoRE4R.lua",
                destinationPath: Path.Combine(re4rInstallPath, "reframework", "autorun", "ArchipelagoRE4R.lua"),
                cancellationToken));

        foreach (var sourcePath in Directory.EnumerateFiles(moduleDirectorySource, "*", SearchOption.AllDirectories)
                     .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            var moduleRelativePath = Path.GetRelativePath(moduleDirectorySource, sourcePath)
                .Replace('\\', '/');
            plannedFiles.Add(
                await BuildLuaPlannedFileAsync(
                    sourcePath,
                    relativePath: $"reframework/autorun/ArchipelagoRE4R/{moduleRelativePath}",
                    destinationPath: Path.Combine(re4rInstallPath, "reframework", "autorun", "ArchipelagoRE4R", moduleRelativePath.Replace('/', Path.DirectorySeparatorChar)),
                    cancellationToken));
        }

        foreach (var sourcePath in Directory.EnumerateFiles(dataDirectorySource, "*", SearchOption.AllDirectories)
                     .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            var dataRelativePath = Path.GetRelativePath(dataDirectorySource, sourcePath)
                .Replace('\\', '/');
            plannedFiles.Add(
                await BuildLuaPlannedFileAsync(
                    sourcePath,
                    relativePath: $"reframework/data/ArchipelagoRE4R/{dataRelativePath}",
                    destinationPath: Path.Combine(re4rInstallPath, "reframework", "data", "ArchipelagoRE4R", dataRelativePath.Replace('/', Path.DirectorySeparatorChar)),
                    cancellationToken));
        }

        // The native AP client library + its license notices ship to the GAME
        // ROOT (next to re4.exe), not under reframework/: REFramework's Lua loads
        // the DLL from the game root via package.loadlib("lua-apclientpp.dll", ...).
        var dllSource = Path.Combine(AssetsNativeDirectoryPath, "lua-apclientpp.dll");
        if (!File.Exists(dllSource))
        {
            throw new InstallException($"Lua mod install could not continue because the bundled lua-apclientpp.dll was not found at {dllSource}.");
        }

        plannedFiles.Add(
            await BuildLuaPlannedFileAsync(
                dllSource,
                relativePath: "lua-apclientpp.dll",
                destinationPath: Path.Combine(re4rInstallPath, "lua-apclientpp.dll"),
                cancellationToken));

        var noticesSource = Path.Combine(AssetsNativeDirectoryPath, "THIRD-PARTY-NOTICES-lua-apclientpp.txt");
        if (!File.Exists(noticesSource))
        {
            throw new InstallException($"Lua mod install could not continue because the bundled THIRD-PARTY-NOTICES-lua-apclientpp.txt was not found at {noticesSource}.");
        }

        plannedFiles.Add(
            await BuildLuaPlannedFileAsync(
                noticesSource,
                relativePath: "THIRD-PARTY-NOTICES-lua-apclientpp.txt",
                destinationPath: Path.Combine(re4rInstallPath, "THIRD-PARTY-NOTICES-lua-apclientpp.txt"),
                cancellationToken));

        return plannedFiles;
    }

    private static async Task<InstallPlannedFile> BuildLuaPlannedFileAsync(
        string sourcePath,
        string relativePath,
        string destinationPath,
        CancellationToken cancellationToken)
    {
        var fileInfo = new FileInfo(sourcePath);
        return new InstallPlannedFile
        {
            RelativePath = relativePath,
            SourcePath = sourcePath,
            DestinationPath = destinationPath,
            Size = fileInfo.Length,
            ExpectedSha256 = await HashingUtilities.ComputeSha256HexAsync(sourcePath, cancellationToken),
        };
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
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
}
