using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Utilities;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class LaunchWorkflowService
{
    private readonly SettingsStore _settingsStore;
    private readonly StaticGameDataProvider _staticGameDataProvider;
    private readonly ArchipelagoScoutClient _archipelagoScoutClient;
    private readonly ManifestBuilder _manifestBuilder;
    private readonly BioRandProcessRunner _bioRandProcessRunner;
    private readonly LuaInstallService _luaInstallService;
    private readonly SessionRecordStore _sessionRecordStore;
    private readonly Func<DateTimeOffset> _utcNow;

    public LaunchWorkflowService(
        SettingsStore? settingsStore = null,
        StaticGameDataProvider? staticGameDataProvider = null,
        ArchipelagoScoutClient? archipelagoScoutClient = null,
        ManifestBuilder? manifestBuilder = null,
        BioRandProcessRunner? bioRandProcessRunner = null,
        LuaInstallService? luaInstallService = null,
        SessionRecordStore? sessionRecordStore = null,
        Func<DateTimeOffset>? utcNow = null)
    {
        _settingsStore = settingsStore ?? new SettingsStore();
        _staticGameDataProvider = staticGameDataProvider ?? new StaticGameDataProvider();
        _archipelagoScoutClient = archipelagoScoutClient ?? new ArchipelagoScoutClient();
        _manifestBuilder = manifestBuilder ?? new ManifestBuilder(_staticGameDataProvider);
        _bioRandProcessRunner = bioRandProcessRunner ?? new BioRandProcessRunner(_settingsStore);
        _luaInstallService = luaInstallService ?? new LuaInstallService();
        _sessionRecordStore = sessionRecordStore ?? new SessionRecordStore(_settingsStore.AppDataRootPath);
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);

        _settingsStore.LogMessage += Log;
        _staticGameDataProvider.LogMessage += Log;
        _archipelagoScoutClient.LogMessage += Log;
        _manifestBuilder.LogMessage += Log;
        _bioRandProcessRunner.LogMessage += Log;
        _luaInstallService.LogMessage += Log;
        _sessionRecordStore.LogMessage += Log;
    }

    public event Action<string>? LogMessage;

    public async Task<LaunchWorkflowResult> RunAsync(
        LaunchWorkflowRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        try
        {
            Log($"Launcher workflow starting for slot {request.SlotName} on {request.ServerAddress}.");
            cancellationToken.ThrowIfCancellationRequested();

            NotifyStepStarting(request, WorkflowStep.ValidateSettings);
            var prerequisites = await ValidatePrerequisitesAsync(request, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

            var settings = await _settingsStore.LoadAsync(cancellationToken);
            NotifyStepStarting(request, WorkflowStep.CheckSetup);
            var setupResult = await EnsureSetupAsync(request, settings, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

            NotifyStepStarting(request, WorkflowStep.ScoutApServer);
            var scoutResult = await ScoutAsync(request, prerequisites.StaticData, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

            NotifyStepStarting(request, WorkflowStep.CheckExistingSession);
            var sessionDecision = await EvaluateSessionAsync(
                request,
                scoutResult,
                prerequisites,
                cancellationToken);
            if (sessionDecision.Cancelled)
            {
                return new LaunchWorkflowResult
                {
                    Success = false,
                    Cancelled = true,
                    CancelledAtStep = sessionDecision.CancelledAtStep,
                    NormalizedServer = scoutResult.NormalizedServer,
                    SeedName = scoutResult.SeedName,
                    SetupResult = setupResult,
                    ScoutResult = scoutResult,
                };
            }

            ManifestBuildResult? manifestResult = null;
            BioRandGenerationResult? generationResult = null;
            InstallResult? patchInstallResult = null;
            InstallResult? luaInstallResult = null;
            var resumedExistingSession = false;
            SessionRecord sessionRecord;

            if (sessionDecision.ResumeValidated)
            {
                resumedExistingSession = true;
                sessionRecord = sessionDecision.SessionRecord!;
                sessionRecord.LastOpenedAtUtc = _utcNow();
                // Mutable metadata refresh: the room may have moved since the
                // last patch (archipelago.gg port churn); identity is seed+slot.
                sessionRecord.NormalizedServer = scoutResult.NormalizedServer;
                if (!string.IsNullOrWhiteSpace(request.RoomUrl))
                {
                    sessionRecord.RoomUrl = request.RoomUrl.Trim();
                }
                sessionRecord.IsHostedSession = request.IsHostedSession;
                sessionRecord.HostedPort = request.IsHostedSession
                    ? TryExtractPort(scoutResult.NormalizedServer)
                    : null;
            }
            else
            {
                // Re-patch pinning: when a record exists for this seed+slot, replay the recorded
                // BioRand options AND seed verbatim so the re-patch reproduces the original world -
                // the plan's "re-patch is safe" promise.
                //
                // UNLESS the player explicitly asked to change them (OverrideRecordedOptions). Now
                // that modes and 419 options are player-editable, silently discarding their picks
                // would make the options screen lie about what it is going to generate. They are
                // warned first that the non-check world re-rolls and they should start a new game;
                // AP checks are pinned by GUID either way, so the multiworld cannot desync.
                var priorRecord = sessionDecision.SessionRecord;
                var replayRecordedOptions = priorRecord is not null && !request.OverrideRecordedOptions;
                var effectiveOptions = replayRecordedOptions
                    ? BioRandOptions.Sanitize(priorRecord!.BioRandOptions)
                    : BioRandOptions.Sanitize(request.BioRandOptions);

                if (priorRecord is not null && request.OverrideRecordedOptions)
                {
                    Log("Re-patching with the NEW options you selected: your multiworld checks stay identical, but the rest of the world is re-rolled. Start a new game.");
                }

                NotifyStepStarting(request, WorkflowStep.BuildManifest);
                manifestResult = await BuildManifestAsync(request, scoutResult, effectiveOptions, cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();

                // Replaying: reuse the recorded seed verbatim -> identical world.
                // Overriding: re-derive from the NEW manifest, so the world stays a pure function of
                // (room, slot, options). That keeps the change reversible - going back to the old
                // options re-derives the old seed and restores the original world exactly.
                var bioRandSeed = replayRecordedOptions && priorRecord!.BioRandSeed is { } recordedSeed
                    ? recordedSeed
                    : ComputeDeterministicSeed(scoutResult.SeedName, request.SlotName, manifestResult.ConfigJson);
                if (replayRecordedOptions)
                {
                    Log("Re-patching an existing session: reusing the recorded BioRand seed and the options from the original patch so the world is reproduced identically.");
                }

                NotifyStepStarting(request, WorkflowStep.RunBioRandGeneration);
                generationResult = await GenerateBioRandAsync(request, manifestResult, bioRandSeed, cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();

                // Breadcrumb BEFORE any game file is touched: a crash or power
                // loss mid-install leaves a patch_in_progress record instead
                // of launcher amnesia over a half-modified install (review:
                // interrupted-patch-recovery). Removed/restored below if the
                // player cancels at the confirm dialog.
                var breadcrumb = BuildInProgressRecord(request, scoutResult, prerequisites, effectiveOptions, bioRandSeed, priorRecord);
                await _sessionRecordStore.SaveAsync(breadcrumb, cancellationToken);

                NotifyStepStarting(request, WorkflowStep.InstallPatchFiles);
                patchInstallResult = await InstallPatchFilesAsync(request, generationResult, cancellationToken);
                if (patchInstallResult.Cancelled)
                {
                    await RestoreRecordAfterCancelledInstallAsync(priorRecord, breadcrumb.SessionKey, cancellationToken);
                    return new LaunchWorkflowResult
                    {
                        Success = false,
                        Cancelled = true,
                        CancelledAtStep = WorkflowStep.InstallPatchFiles,
                        NormalizedServer = scoutResult.NormalizedServer,
                        SeedName = scoutResult.SeedName,
                        SetupResult = setupResult,
                        ScoutResult = scoutResult,
                        ManifestResult = manifestResult,
                        GenerationResult = generationResult,
                        PatchInstallResult = patchInstallResult,
                    };
                }

                if (!patchInstallResult.Success)
                {
                    throw new WorkflowException(
                        WorkflowStep.InstallPatchFiles,
                        BuildInstallVerificationFailureMessage("BioRand patch install", patchInstallResult));
                }

                cancellationToken.ThrowIfCancellationRequested();

                NotifyStepStarting(request, WorkflowStep.InstallLuaModFiles);
                luaInstallResult = await InstallLuaModFilesAsync(request, cancellationToken);
                if (luaInstallResult.Cancelled)
                {
                    return new LaunchWorkflowResult
                    {
                        Success = false,
                        Cancelled = true,
                        CancelledAtStep = WorkflowStep.InstallLuaModFiles,
                        NormalizedServer = scoutResult.NormalizedServer,
                        SeedName = scoutResult.SeedName,
                        SetupResult = setupResult,
                        ScoutResult = scoutResult,
                        ManifestResult = manifestResult,
                        GenerationResult = generationResult,
                        PatchInstallResult = patchInstallResult,
                        LuaInstallResult = luaInstallResult,
                    };
                }

                if (!luaInstallResult.Success)
                {
                    throw new WorkflowException(
                        WorkflowStep.InstallLuaModFiles,
                        BuildInstallVerificationFailureMessage("Lua mod install", luaInstallResult));
                }

                sessionRecord = await BuildSessionRecordAsync(
                    request,
                    scoutResult,
                    prerequisites,
                    manifestResult,
                    generationResult,
                    patchInstallResult,
                    luaInstallResult,
                    settings,
                    effectiveOptions,
                    bioRandSeed,
                    priorRecord,
                    cancellationToken);
            }

            cancellationToken.ThrowIfCancellationRequested();

            await NotifyAsync(
                request,
                WorkflowStep.SaveFileSafetyWarning,
                "Make sure you are using a save file started on this AP seed before launching RE4R.");

            NotifyStepStarting(request, WorkflowStep.WriteSessionRecord);
            sessionRecord.LastOpenedAtUtc = _utcNow();
            await SaveSessionRecordAsync(sessionRecord, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

            NotifyStepStarting(request, WorkflowStep.WriteConnectionInfo);
            var connectionInfoResult = await WriteConnectionInfoAsync(
                request,
                scoutResult.NormalizedServer,
                scoutResult,
                cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

            // The relaunch line is the whole ballgame: REFramework only loads
            // the Archipelago scripts at game start, so a player who patches
            // while RE4R is running sees "nothing works" and reports a bug.
            var finalMessage = request.IsHostedSession
                ? "Your game is patched and ready.\n\n"
                    + "1. If RE4R is running, quit it completely.\n"
                    + "2. Start RE4R from Steam - it connects to the multiworld automatically.\n"
                    + "3. Press Insert in-game to open the Archipelago window.\n\n"
                    + "Keep this window open - closing it stops your AP server."
                : "Your game is patched and ready.\n\n"
                    + "1. If RE4R is running, quit it completely.\n"
                    + "2. Start RE4R from Steam - it connects to the multiworld automatically.\n"
                    + "3. Press Insert in-game to open the Archipelago window.\n\n"
                    + "You can close this window now. Come back only to patch a new seed.";
            Log(finalMessage);

            return new LaunchWorkflowResult
            {
                Success = true,
                Cancelled = false,
                ResumedExistingSession = resumedExistingSession,
                NormalizedServer = scoutResult.NormalizedServer,
                SeedName = scoutResult.SeedName,
                SetupResult = setupResult,
                ScoutResult = scoutResult,
                ManifestResult = manifestResult,
                GenerationResult = generationResult,
                PatchInstallResult = patchInstallResult,
                LuaInstallResult = luaInstallResult,
                ConnectionInfoResult = connectionInfoResult,
                SessionRecord = sessionRecord,
                FinalMessage = finalMessage,
            };
        }
        catch (WorkflowException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new WorkflowException(
                WorkflowStep.Unknown,
                "The launcher workflow failed unexpectedly. Check the log for the last completed step and try again.",
                ex);
        }
    }

    private async Task<PrerequisiteValidationResult> ValidatePrerequisitesAsync(
        LaunchWorkflowRequest request,
        CancellationToken cancellationToken)
    {
        Log("Checking launcher settings and required files.");

        if (string.IsNullOrWhiteSpace(request.Re4rInstallPath) || !Directory.Exists(request.Re4rInstallPath))
        {
            throw new WorkflowException(
                WorkflowStep.ValidateSettings,
                $"The selected RE4R install path was not found: {request.Re4rInstallPath}. Choose your real game folder and try again.");
        }
        Log($"RE4R install path found at {request.Re4rInstallPath}.");

        if (string.IsNullOrWhiteSpace(request.ServerAddress))
        {
            throw new WorkflowException(WorkflowStep.ValidateSettings, "The AP server address is empty. Enter the server address in the Session section and try again.");
        }
        Log($"AP server address entered: {request.ServerAddress}.");

        if (string.IsNullOrWhiteSpace(request.SlotName))
        {
            throw new WorkflowException(WorkflowStep.ValidateSettings, "The AP slot name is empty. Enter your slot name in the Session section and try again.");
        }
        Log($"AP slot name entered: {request.SlotName}.");

        if (string.IsNullOrWhiteSpace(request.GameVersion))
        {
            throw new WorkflowException(WorkflowStep.ValidateSettings, "No BioRand game-version was selected. Pick the detected version or choose one manually in Setup and try again.");
        }
        Log($"BioRand game-version selected: {request.GameVersion}.");

        try
        {
            Log("Checking bundled static world data.");
            var staticData = await _staticGameDataProvider.LoadAsync(cancellationToken);
            var staticDataHash = await HashingUtilities.ComputeSha256HexAsync(
                _staticGameDataProvider.StaticDataFilePath,
                cancellationToken);
            Log($"Static world data hash: {staticDataHash}.");

            Log("Checking bundled BioRand executable.");
            var bioRandVersionDescriptor = _bioRandProcessRunner.GetBioRandVersionDescriptor();
            Log($"BioRand binary resolved as {bioRandVersionDescriptor}.");

            return new PrerequisiteValidationResult(
                StaticData: staticData,
                StaticDataHash: staticDataHash,
                BioRandVersionDescriptor: bioRandVersionDescriptor);
        }
        catch (StaticGameDataException ex)
        {
            throw new WorkflowException(
                WorkflowStep.ValidateSettings,
                ex.Message,
                ex);
        }
        catch (BioRandProcessException ex)
        {
            throw new WorkflowException(
                WorkflowStep.ValidateSettings,
                ex.Message,
                ex);
        }
    }

    private async Task<BioRandSetupResult?> EnsureSetupAsync(
        LaunchWorkflowRequest request,
        LauncherSettings settings,
        CancellationToken cancellationToken)
    {
        Log("Checking whether BioRand setup is current for this game install.");

        var normalizedFingerprint = GameFingerprint.Sanitize(request.CurrentGameFingerprint);
        // Move any pre-2026-07-12 cache out of roaming AppData first, so the
        // cache-exists check below sees it at the new LocalAppData location.
        _bioRandProcessRunner.MigrateLegacyCacheIfNeeded();
        // The cache must be rebuilt when the GAME changes AND when BIORAND
        // changes: a newer BioRand can read files an older setup never
        // harvested (the step-0 "Unable to find lights scene" crash came from
        // exactly this - a stale cache surviving a BioRand upgrade). It must
        // ALSO actually exist on disk - settings flags alone are not enough:
        // a cleared cache, a failed migration, or a relocated cache would
        // otherwise skip setup and fail generation with "run setup first".
        var currentBioRandVersion = _bioRandProcessRunner.GetBioRandVersionDescriptor();
        var setupIsCurrent = !string.IsNullOrWhiteSpace(settings.SetupGameFingerprint)
            && string.Equals(settings.SetupGameFingerprint, normalizedFingerprint.FingerprintHash, StringComparison.Ordinal)
            && string.Equals(settings.SetupBioRandVersion, currentBioRandVersion, StringComparison.Ordinal)
            && Directory.Exists(_bioRandProcessRunner.BioRandCacheDirectoryPath);

        if (setupIsCurrent)
        {
            // A cache harvested by a pre-shield launcher while a patch pak was
            // installed passes the settings checks but carries patched files -
            // generation then crashes on already-patched scenes. Re-verify and
            // rebuild instead of trusting the bookkeeping.
            var cachePoisonMessage = _bioRandProcessRunner.VerifyHarvestIsVanilla(request.Re4rInstallPath);
            if (cachePoisonMessage is null)
            {
                Log("BioRand setup matches the current game fingerprint and BioRand version. Setup does not need to run again.");
                return null;
            }

            Log("The BioRand cache failed the vanilla check - it was probably harvested while a patch pak was installed. Rebuilding it now.");
            Log(cachePoisonMessage);
        }

        Log(string.IsNullOrWhiteSpace(settings.SetupGameFingerprint)
            ? "BioRand setup has never been run for this install. Setup will run now."
            : "BioRand setup is stale (game fingerprint or BioRand version changed). Setup will run again now.");

        await NotifyAsync(
            request,
            WorkflowStep.CheckSetup,
            string.IsNullOrWhiteSpace(settings.SetupGameFingerprint)
                ? "BioRand setup has not been run for this install yet. Running setup now."
                : "The game or the launcher's bundled BioRand changed since setup last ran. Rebuilding the vanilla file cache now.");

        var ourPatchFileNames = await CollectRecordedPatchFileNamesAsync(cancellationToken);

        // Catch a modded game BEFORE spending a minute harvesting it. The
        // harvest reads the whole pak stack, so a leftover mod pak silently
        // becomes "vanilla" in the cache and every later generation crashes on
        // scenes that do not match the real game.
        var foreignPaks = _bioRandProcessRunner.FindForeignPatchPaks(
            request.Re4rInstallPath,
            request.GameVersion,
            ourPatchFileNames);
        if (foreignPaks.Count > 0)
        {
            Log($"Found {foreignPaks.Count} patch pak(s) in the game folder that are neither vanilla nor ours: {string.Join(", ", foreignPaks)}");
            if (request.ConfirmForeignPatchPaksAsync is not null
                && !await request.ConfirmForeignPatchPaksAsync(foreignPaks))
            {
                throw new WorkflowException(
                    WorkflowStep.CheckSetup,
                    "Stopped so you can remove the extra patch paks. Delete them from your RE4R folder, then patch again.");
            }
        }

        try
        {
            var result = await _bioRandProcessRunner.RunSetupAsync(
                new BioRandSetupRequest
                {
                    Re4rInstallPath = request.Re4rInstallPath,
                    GameFingerprint = normalizedFingerprint,
                    ApPatchFileNames = ourPatchFileNames,
                },
                cancellationToken);

            if (!result.Success)
            {
                throw new WorkflowException(
                    WorkflowStep.CheckSetup,
                    string.IsNullOrWhiteSpace(result.ErrorMessage)
                        ? "BioRand setup failed."
                        : result.ErrorMessage);
            }

            return result;
        }
        catch (BioRandProcessException ex)
        {
            throw new WorkflowException(
                WorkflowStep.CheckSetup,
                ex.Message,
                ex);
        }
    }

    /// <summary>
    /// Every patch pak any session record has ever staged, by file name. Setup
    /// must harvest the VANILLA game, and re-patch flows run setup while the
    /// previous patch pak is still installed (the 2026-07-21 poisoned-cache
    /// crash: the harvest baked our own pak into the "vanilla" cache and
    /// generation died on the already-patched cabin-door scene).
    /// </summary>
    private async Task<IReadOnlyList<string>> CollectRecordedPatchFileNamesAsync(CancellationToken cancellationToken)
    {
        var records = await _sessionRecordStore.LoadAllAsync(cancellationToken);
        return records
            .SelectMany(record => record.BioRandPatchFiles)
            .Select(file => Path.GetFileName(file.RelativePath))
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private async Task<ArchipelagoScoutSessionResult> ScoutAsync(
        LaunchWorkflowRequest request,
        StaticGameData staticData,
        CancellationToken cancellationToken)
    {
        Log("Scouting the AP server for placement data.");

        try
        {
            var result = await _archipelagoScoutClient.ScoutLocationsAsync(
                new ArchipelagoScoutRequest
                {
                    ServerAddress = request.ServerAddress,
                    SlotName = request.SlotName,
                    Password = request.Password,
                    GameName = staticData.Game,
                    LocationIds = staticData.LocationCodes,
                },
                cancellationToken);

            var realOwnCount = 0;
            var placeholderCount = 0;
            var skippedNoGuidCount = 0;
            foreach (var location in result.Locations)
            {
                if (!staticData.Locations.TryGetValue(location.LocationId, out var staticLocation)
                    || string.IsNullOrWhiteSpace(staticLocation.Guid))
                {
                    skippedNoGuidCount++;
                    continue;
                }

                if (location.OwningPlayerSlot == result.ConnectedPlayerSlot)
                {
                    realOwnCount++;
                }
                else
                {
                    placeholderCount++;
                }
            }

            Log(
                $"Scout summary: {result.Locations.Count} assignments received, " +
                $"{realOwnCount} own RE4R items, {placeholderCount} placeholder items for other players, " +
                $"{skippedNoGuidCount} no-GUID locations that will be skipped by the BioRand manifest.");
            return result;
        }
        catch (ArchipelagoScoutException ex)
        {
            throw new WorkflowException(
                WorkflowStep.ScoutApServer,
                ex.Message,
                ex);
        }
    }

    private async Task<SessionDecisionResult> EvaluateSessionAsync(
        LaunchWorkflowRequest request,
        ArchipelagoScoutSessionResult scoutResult,
        PrerequisiteValidationResult prerequisites,
        CancellationToken cancellationToken)
    {
        // Identity is seed+slot (the seed is scouted, so this runs post-scout
        // by construction). Conflicts are ANY other open session, regardless
        // of server or slot: the RE4R install is physically patched for one
        // multiworld at a time.
        var sessionKey = ComputeSessionKey(request, scoutResult);
        Log($"Checking for existing sessions for slot {request.SlotName} on seed {scoutResult.SeedName}.");
        var openRecords = await _sessionRecordStore.LoadOpenSessionsAsync(cancellationToken);

        var sameSessionRecord = openRecords.FirstOrDefault(
                record => string.Equals(record.SessionKey, sessionKey, StringComparison.Ordinal))
            ?? await _sessionRecordStore.TryLoadBySessionKeyAsync(sessionKey, cancellationToken);
        var conflictingRecord = openRecords.FirstOrDefault(
            record => !string.Equals(record.SessionKey, sessionKey, StringComparison.Ordinal));

        if (conflictingRecord is not null)
        {
            Log($"Another multiworld is currently patched or in progress: slot {conflictingRecord.SlotName} on seed {conflictingRecord.SeedName} ({conflictingRecord.NormalizedServer}). Incoming seed: {scoutResult.SeedName}.");
            if (request.ConfirmOverwriteDifferentSeedAsync is null)
            {
                throw new WorkflowException(
                    WorkflowStep.CheckExistingSession,
                    "A different-multiworld confirmation delegate was not provided.");
            }

            var confirmed = await request.ConfirmOverwriteDifferentSeedAsync(
                new ExistingSessionConflictPrompt
                {
                    NormalizedServer = conflictingRecord.NormalizedServer,
                    SlotName = conflictingRecord.SlotName,
                    ExistingSeedName = conflictingRecord.SeedName,
                    IncomingSeedName = scoutResult.SeedName,
                    ExistingPatchedAtUtc = conflictingRecord.PatchedAtUtc,
                });

            if (!confirmed)
            {
                Log("User declined to replace the currently patched multiworld.");
                return new SessionDecisionResult(Cancelled: true, CancelledAtStep: WorkflowStep.CheckExistingSession);
            }

            Log("User confirmed the currently patched multiworld may be replaced (switching back later is safe - re-patching reproduces it identically).");
        }

        if (sameSessionRecord is null)
        {
            Log("No saved session record was found for this seed and slot. A fresh patch will be created.");
            return new SessionDecisionResult(
                SessionKey: sessionKey,
                ResumeValidated: false);
        }

        if (string.Equals(sameSessionRecord.Status, "patch_in_progress", StringComparison.OrdinalIgnoreCase))
        {
            // A previous patch of this exact session was interrupted mid-install.
            // Re-running the patch IS the recovery mechanism: the recorded seed
            // and options reproduce an identical WORLD (same items, same places), so skip
            // the resume prompt. NOTE: the pak is never byte-identical - BioRand stamps
            // fresh Guid.NewGuid() object ids per run. Never verify a patch by pak hash.
            Log("The last patch of this session did not finish. Patching again now - this is safe: it rebuilds the same world, with the same items in the same places.");
            return new SessionDecisionResult(
                SessionKey: sessionKey,
                SessionRecord: sameSessionRecord,
                ResumeValidated: false);
        }

        if (request.ChooseResumeActionAsync is null)
        {
            throw new WorkflowException(
                WorkflowStep.CheckExistingSession,
                "A resume vs re-patch decision delegate was not provided.");
        }

        Log($"Found an existing saved session for seed {sameSessionRecord.SeedName}. Asking whether to resume or re-patch.");
        var decision = await request.ChooseResumeActionAsync(
            new ResumeSessionPrompt
            {
                NormalizedServer = scoutResult.NormalizedServer,
                SlotName = request.SlotName,
                SeedName = scoutResult.SeedName,
                PatchedAtUtc = sameSessionRecord.PatchedAtUtc,
            });

        if (decision == ResumeSessionDecision.Cancel)
        {
            Log("User cancelled at the resume vs re-patch prompt.");
            return new SessionDecisionResult(Cancelled: true, CancelledAtStep: WorkflowStep.CheckExistingSession);
        }

        if (decision == ResumeSessionDecision.RePatch)
        {
            Log("User chose to re-patch the current seed.");
            return new SessionDecisionResult(
                SessionKey: sessionKey,
                SessionRecord: sameSessionRecord,
                ResumeValidated: false);
        }

        var resumeValidation = await ValidateResumeAsync(
            sameSessionRecord,
            prerequisites,
            request,
            cancellationToken);

        if (!resumeValidation.IsValid)
        {
            Log($"Resume validation failed: {resumeValidation.Reason}. Re-patch is required.");
            return new SessionDecisionResult(
                SessionKey: sessionKey,
                SessionRecord: sameSessionRecord,
                ResumeValidated: false);
        }

        Log("Resume validation passed. Existing session files still match the recorded patch.");
        return new SessionDecisionResult(
            SessionKey: sessionKey,
            SessionRecord: sameSessionRecord,
            ResumeValidated: true);
    }

    private async Task<ResumeValidationResult> ValidateResumeAsync(
        SessionRecord sessionRecord,
        PrerequisiteValidationResult prerequisites,
        LaunchWorkflowRequest request,
        CancellationToken cancellationToken)
    {
        if (!string.Equals(
                sessionRecord.GameFingerprintAtPatch.FingerprintHash,
                request.CurrentGameFingerprint.FingerprintHash,
                StringComparison.Ordinal))
        {
            Log("Resume check: game fingerprint mismatch.");
            return new ResumeValidationResult(false, "The game fingerprint changed since the last patch.");
        }
        Log("Resume check: game fingerprint matches the last patch.");

        if (!string.Equals(sessionRecord.WorldVersion, prerequisites.StaticData.WorldVersion, StringComparison.Ordinal))
        {
            Log("Resume check: bundled world version mismatch.");
            return new ResumeValidationResult(false, "The bundled world version changed since the last patch.");
        }
        Log("Resume check: bundled world version matches the last patch.");

        if (!string.Equals(sessionRecord.StaticDataHash, prerequisites.StaticDataHash, StringComparison.Ordinal))
        {
            Log("Resume check: bundled static data hash mismatch.");
            return new ResumeValidationResult(false, "The bundled static data changed since the last patch.");
        }
        Log("Resume check: bundled static data hash matches the last patch.");

        var patchFilesValid = await VerifyInstalledFilesAsync(
            request.Re4rInstallPath,
            sessionRecord.BioRandPatchFiles,
            cancellationToken);
        if (!patchFilesValid)
        {
            return new ResumeValidationResult(false, "BioRand patch files no longer match the recorded hashes.");
        }

        var luaFilesValid = await VerifyInstalledFilesAsync(
            request.Re4rInstallPath,
            sessionRecord.LuaCopyFiles,
            cancellationToken);
        if (!luaFilesValid)
        {
            return new ResumeValidationResult(false, "Lua mod files no longer match the recorded hashes.");
        }

        return new ResumeValidationResult(true, string.Empty);
    }

    private async Task<bool> VerifyInstalledFilesAsync(
        string installRoot,
        IReadOnlyList<StagedFileEntry> files,
        CancellationToken cancellationToken)
    {
        foreach (var file in files)
        {
            var destinationPath = Path.Combine(installRoot, file.RelativePath.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(destinationPath))
            {
                Log($"Resume verification failed because {destinationPath} is missing.");
                return false;
            }

            var actualHash = await HashingUtilities.ComputeSha256HexAsync(destinationPath, cancellationToken);
            if (!string.Equals(actualHash, file.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                Log($"Resume verification failed because {file.RelativePath} hash did not match.");
                return false;
            }

            Log($"Resume verification passed for {file.RelativePath}.");
        }

        return true;
    }

    private async Task<ManifestBuildResult> BuildManifestAsync(
        LaunchWorkflowRequest request,
        ArchipelagoScoutSessionResult scoutResult,
        BioRandOptions effectiveOptions,
        CancellationToken cancellationToken)
    {
        try
        {
            Log("Building the BioRand AP manifest.");
            return await _manifestBuilder.BuildAsync(
                scoutResult,
                effectiveOptions,
                request.GameVersion,
                cancellationToken);
        }
        catch (ManifestBuildException ex)
        {
            throw new WorkflowException(
                WorkflowStep.BuildManifest,
                ex.Message,
                ex);
        }
    }

    private async Task<BioRandGenerationResult> GenerateBioRandAsync(
        LaunchWorkflowRequest request,
        ManifestBuildResult manifestResult,
        int bioRandSeed,
        CancellationToken cancellationToken)
    {
        try
        {
            Log($"Using deterministic BioRand seed {bioRandSeed} for this session.");
            var result = await _bioRandProcessRunner.RunGenerationAsync(
                new BioRandGenerationRequest
                {
                    Re4rInstallPath = request.Re4rInstallPath,
                    Seed = bioRandSeed,
                    ConfigJson = manifestResult.ConfigJson,
                },
                cancellationToken);

            if (!result.Success)
            {
                throw new WorkflowException(
                    WorkflowStep.RunBioRandGeneration,
                    string.IsNullOrWhiteSpace(result.ErrorMessage)
                        ? "BioRand generation failed."
                        : result.ErrorMessage);
            }

            Log($"BioRand generation staged {result.StagedFiles.Count} file(s) at {result.StagingDirectoryPath}.");
            return result;
        }
        catch (BioRandProcessException ex)
        {
            throw new WorkflowException(
                WorkflowStep.RunBioRandGeneration,
                ex.Message,
                ex);
        }
    }

    private async Task<InstallResult> InstallPatchFilesAsync(
        LaunchWorkflowRequest request,
        BioRandGenerationResult generationResult,
        CancellationToken cancellationToken)
    {
        if (request.ConfirmPatchInstallAsync is null)
        {
            throw new WorkflowException(
                WorkflowStep.InstallPatchFiles,
                "A patch install confirmation delegate was not provided.");
        }

        try
        {
            Log("Starting staged patch-file install.");
            return await _luaInstallService.InstallPatchFilesAsync(
                generationResult,
                request.Re4rInstallPath,
                request.ConfirmPatchInstallAsync,
                cancellationToken);
        }
        catch (InstallException ex)
        {
            throw new WorkflowException(
                WorkflowStep.InstallPatchFiles,
                ex.Message,
                ex);
        }
    }

    private async Task<InstallResult> InstallLuaModFilesAsync(
        LaunchWorkflowRequest request,
        CancellationToken cancellationToken)
    {
        if (request.ConfirmLuaInstallAsync is null)
        {
            throw new WorkflowException(
                WorkflowStep.InstallLuaModFiles,
                "A Lua install confirmation delegate was not provided.");
        }

        try
        {
            Log("Starting Lua mod file install.");
            return await _luaInstallService.InstallLuaModFilesAsync(
                request.Re4rInstallPath,
                request.ConfirmLuaInstallAsync,
                cancellationToken);
        }
        catch (InstallException ex)
        {
            throw new WorkflowException(
                WorkflowStep.InstallLuaModFiles,
                ex.Message,
                ex);
        }
    }

    private static string BuildInstallVerificationFailureMessage(string operationLabel, InstallResult installResult)
    {
        return $"The {operationLabel} copied {installResult.FilesCopiedCount} file(s), but "
            + $"{installResult.VerificationFailures.Count} of them failed hash verification, so the install cannot be trusted. "
            + "Make sure no other program (like an antivirus or the game itself) is using the RE4R folder, then patch again.";
    }

    private async Task<SessionRecord> BuildSessionRecordAsync(
        LaunchWorkflowRequest request,
        ArchipelagoScoutSessionResult scoutResult,
        PrerequisiteValidationResult prerequisites,
        ManifestBuildResult manifestResult,
        BioRandGenerationResult generationResult,
        InstallResult patchInstallResult,
        InstallResult luaInstallResult,
        LauncherSettings settings,
        BioRandOptions effectiveOptions,
        int bioRandSeed,
        SessionRecord? priorRecord,
        CancellationToken cancellationToken)
    {
        var patchFiles = generationResult.StagedFiles
            .Select(file => new StagedFileEntry
            {
                RelativePath = file.RelativePath,
                Sha256 = file.Sha256,
                Size = file.Size,
            })
            .ToList();

        var luaFiles = await BuildLuaSessionFilesAsync(cancellationToken).ConfigureAwait(false);

        return new SessionRecord
        {
            SessionKey = ComputeSessionKey(request, scoutResult),
            NormalizedServer = scoutResult.NormalizedServer,
            RoomUrl = !string.IsNullOrWhiteSpace(request.RoomUrl)
                ? request.RoomUrl.Trim()
                : priorRecord?.RoomUrl ?? string.Empty,
            IsHostedSession = request.IsHostedSession,
            HostedPort = request.IsHostedSession ? TryExtractPort(scoutResult.NormalizedServer) : null,
            SlotName = request.SlotName,
            SeedName = scoutResult.SeedName,
            Status = "active",
            CreatedAtUtc = priorRecord?.CreatedAtUtc ?? _utcNow(),
            LastOpenedAtUtc = _utcNow(),
            PatchedAtUtc = _utcNow(),
            WorldVersion = prerequisites.StaticData.WorldVersion,
            StaticDataHash = prerequisites.StaticDataHash,
            InstallPathAtPatch = request.Re4rInstallPath,
            GameFingerprintAtPatch = GameFingerprint.Sanitize(request.CurrentGameFingerprint),
            BioRandVersionAtPatch = generationResult.BioRandVersionDescriptor,
            BioRandGameVersionAtPatch = request.GameVersion,
            SetupGameFingerprintAtPatch = settings.SetupGameFingerprint,
            SetupCompletedAtUtc = settings.SetupCompletedAtUtc,
            SetupBioRandVersionAtPatch = settings.SetupBioRandVersion,
            PlaceholderItemId = prerequisites.StaticData.PlaceholderItemId,
            ScoutedLocationCount = scoutResult.Locations.Count,
            GuidManifestLocationCount = manifestResult.GuidPlacementCount,
            NoGuidSkippedLocationCount = manifestResult.SkippedNoGuidLocationCount,
            BioRandSeed = bioRandSeed,
            BioRandOptions = BioRandOptions.Sanitize(effectiveOptions),
            BioRandPatchFiles = patchFiles,
            LuaCopyFiles = luaFiles,
        };
    }

    /// <summary>
    /// Minimal breadcrumb saved after generation but BEFORE the first game
    /// file is copied. If the install is interrupted (crash, power loss), the
    /// landing can surface "your last patch didn't finish - patch again
    /// (safe, rebuilds the same world)" instead of forgetting a half-modified install.
    /// </summary>
    private SessionRecord BuildInProgressRecord(
        LaunchWorkflowRequest request,
        ArchipelagoScoutSessionResult scoutResult,
        PrerequisiteValidationResult prerequisites,
        BioRandOptions effectiveOptions,
        int bioRandSeed,
        SessionRecord? priorRecord)
    {
        return new SessionRecord
        {
            SessionKey = ComputeSessionKey(request, scoutResult),
            NormalizedServer = scoutResult.NormalizedServer,
            RoomUrl = !string.IsNullOrWhiteSpace(request.RoomUrl)
                ? request.RoomUrl.Trim()
                : priorRecord?.RoomUrl ?? string.Empty,
            IsHostedSession = request.IsHostedSession,
            SlotName = request.SlotName,
            SeedName = scoutResult.SeedName,
            Status = "patch_in_progress",
            CreatedAtUtc = priorRecord?.CreatedAtUtc ?? _utcNow(),
            LastOpenedAtUtc = _utcNow(),
            PatchedAtUtc = priorRecord?.PatchedAtUtc ?? default,
            WorldVersion = prerequisites.StaticData.WorldVersion,
            StaticDataHash = prerequisites.StaticDataHash,
            InstallPathAtPatch = request.Re4rInstallPath,
            GameFingerprintAtPatch = GameFingerprint.Sanitize(request.CurrentGameFingerprint),
            BioRandGameVersionAtPatch = request.GameVersion,
            BioRandSeed = bioRandSeed,
            BioRandOptions = BioRandOptions.Sanitize(effectiveOptions),
        };
    }

    private async Task RestoreRecordAfterCancelledInstallAsync(
        SessionRecord? priorRecord,
        string sessionKey,
        CancellationToken cancellationToken)
    {
        // The player cancelled at the confirm dialog, so no game file was
        // touched: the breadcrumb must not linger. If this session had a
        // completed patch before, put that record back; otherwise remove it.
        if (priorRecord is not null)
        {
            await _sessionRecordStore.SaveAsync(priorRecord, cancellationToken);
            Log("Restored the previous session record after the cancelled install.");
        }
        else
        {
            await _sessionRecordStore.DeleteAsync(sessionKey, cancellationToken);
        }
    }

    /// <summary>
    /// Minimal teardown (redesign step 2): the player is done with this
    /// multiworld. Marks the record finished and removes the game-local
    /// connection file so RE4R stops auto-connecting to a dead room on every
    /// casual launch. When <paramref name="restoreVanilla"/> is set, also
    /// removes the BioRand patch pak(s) recorded for this session so RE4R plays
    /// as vanilla again (the player can re-patch this or another multiworld
    /// anytime; Steam's Verify Integrity remains the fallback if a file is
    /// locked because the game is still running).
    /// </summary>
    public async Task<SessionRetireResult> RetireSessionAsync(
        SessionRecord record,
        bool restoreVanilla = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(record);

        await _sessionRecordStore.MarkFinishedAsync(record.SessionKey, cancellationToken);

        try
        {
            var gameConnectionInfoPath = Path.Combine(
                record.InstallPathAtPatch, "reframework", "data", "ArchipelagoRE4R", "ap_connection.json");
            if (File.Exists(gameConnectionInfoPath))
            {
                File.Delete(gameConnectionInfoPath);
                Log($"Removed the game-local connection info at {gameConnectionInfoPath} - RE4R will no longer auto-connect for this session.");
            }

            var roomLocationsPath = Path.Combine(
                record.InstallPathAtPatch, "reframework", "data", "ArchipelagoRE4R", "ap_room_locations.json");
            if (File.Exists(roomLocationsPath))
            {
                File.Delete(roomLocationsPath);
                Log($"Removed the room location list at {roomLocationsPath}.");
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log($"Could not remove the game-local connection info: {ex.Message}");
        }

        if (!restoreVanilla)
        {
            return new SessionRetireResult { RestoreVanillaRequested = false };
        }

        // Restore vanilla: delete the BioRand patch pak(s) this session installed
        // into the game folder. Best-effort per file so one locked pak (e.g. RE4R
        // still running) does not strand the rest; the UI reports the counts.
        var removed = 0;
        var failed = 0;
        foreach (var patchFile in record.BioRandPatchFiles)
        {
            if (string.IsNullOrWhiteSpace(patchFile.RelativePath))
            {
                continue;
            }

            var fullPath = Path.Combine(record.InstallPathAtPatch, patchFile.RelativePath);
            try
            {
                if (File.Exists(fullPath))
                {
                    File.Delete(fullPath);
                    Log($"Removed BioRand patch file {patchFile.RelativePath} to restore vanilla RE4R.");
                }
                removed++;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                failed++;
                Log($"Could not remove BioRand patch file {patchFile.RelativePath}: {ex.Message}. If RE4R is running, close it and retire again, or use Steam > Verify integrity of game files.");
            }
        }

        Log(failed == 0
            ? $"Restored vanilla RE4R: removed {removed} BioRand patch file(s)."
            : $"Restore vanilla partially completed: removed {removed}, could not remove {failed}. Close RE4R and retire again, or use Steam > Verify integrity of game files.");

        return new SessionRetireResult
        {
            RestoreVanillaRequested = true,
            PatchFilesRemoved = removed,
            PatchFilesFailed = failed,
        };
    }

    private async Task<List<StagedFileEntry>> BuildLuaSessionFilesAsync(CancellationToken cancellationToken)
    {
        var result = new List<StagedFileEntry>();

        var rootScriptPath = Path.Combine(_luaInstallService.AssetsLuaDirectoryPath, "ArchipelagoRE4R.lua");
        var moduleDirectoryPath = Path.Combine(_luaInstallService.AssetsLuaDirectoryPath, "ArchipelagoRE4R");
        var dataDirectoryPath = Path.Combine(_luaInstallService.AssetsLuaDirectoryPath, "data", "ArchipelagoRE4R");

        foreach (var (sourcePath, relativePath) in EnumerateLuaSourceFiles(rootScriptPath, moduleDirectoryPath, dataDirectoryPath))
        {
            var hash = await HashingUtilities.ComputeSha256HexAsync(sourcePath, cancellationToken).ConfigureAwait(false);
            var size = new FileInfo(sourcePath).Length;
            result.Add(
                new StagedFileEntry
                {
                    RelativePath = relativePath,
                    Sha256 = hash,
                    Size = size,
                });
        }

        return result
            .OrderBy(entry => entry.RelativePath, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static IEnumerable<(string SourcePath, string RelativePath)> EnumerateLuaSourceFiles(
        string rootScriptPath,
        string moduleDirectoryPath,
        string dataDirectoryPath)
    {
        yield return (rootScriptPath, "reframework/autorun/ArchipelagoRE4R.lua");

        foreach (var filePath in Directory.EnumerateFiles(moduleDirectoryPath, "*", SearchOption.AllDirectories)
                     .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            yield return (
                filePath,
                $"reframework/autorun/ArchipelagoRE4R/{Path.GetRelativePath(moduleDirectoryPath, filePath).Replace('\\', '/')}");
        }

        foreach (var filePath in Directory.EnumerateFiles(dataDirectoryPath, "*", SearchOption.AllDirectories)
                     .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            yield return (
                filePath,
                $"reframework/data/ArchipelagoRE4R/{Path.GetRelativePath(dataDirectoryPath, filePath).Replace('\\', '/')}");
        }
    }

    private async Task SaveSessionRecordAsync(SessionRecord sessionRecord, CancellationToken cancellationToken)
    {
        try
        {
            Log($"Saving session record {sessionRecord.SessionKey}.");
            await _sessionRecordStore.SupersedeOtherActiveSessionsAsync(
                sessionRecord.SessionKey,
                cancellationToken);
            await _sessionRecordStore.SaveAsync(sessionRecord, cancellationToken);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new WorkflowException(
                WorkflowStep.WriteSessionRecord,
                "The launcher could not write the session record to AppData. Check that the folder is writable and try again.",
                ex);
        }
    }

    private async Task<ConnectionInfoWriteResult> WriteConnectionInfoAsync(
        LaunchWorkflowRequest request,
        string normalizedServer,
        ArchipelagoScoutSessionResult scoutResult,
        CancellationToken cancellationToken)
    {
        try
        {
            var connectionInfo = new ApConnectionInfo
            {
                ServerAddress = normalizedServer,
                SlotName = request.SlotName,
                Password = request.Password ?? string.Empty,
                // Carried into the game folder so the in-game port-recovery
                // dialog can point the player at their room page.
                RoomUrl = request.RoomUrl?.Trim() ?? string.Empty,
            };

            var connectionInfoPath = Path.Combine(_settingsStore.AppDataRootPath, "ap_connection.json");
            Log($"Writing AP connection info for server {normalizedServer} and slot {request.SlotName}.");
            Directory.CreateDirectory(_settingsStore.AppDataRootPath);
            var json = JsonSerializer.Serialize(connectionInfo, new JsonSerializerOptions { WriteIndented = true });
            await File.WriteAllTextAsync(connectionInfoPath, json, cancellationToken);

            Log($"Wrote AP connection info to {connectionInfoPath}.");
            // The %APPDATA% copy of ap_connection.json is read by the launcher's
            // own reconnect/room-heal flow. The mod's bridge store is NOT here -
            // it lives game-relative at reframework/data/ArchipelagoRE4R/bridge
            // (created below), so no bridge directory is needed beside this file.

            // Also write connection info into the game-relative reframework/data
            // folder so the Lua mod can read it without os.getenv (REFramework's
            // Lua sandbox removes os.getenv, so it cannot resolve %APPDATA%).
            if (!string.IsNullOrWhiteSpace(request.Re4rInstallPath))
            {
                var gameDataDirectoryPath = Path.Combine(
                    request.Re4rInstallPath, "reframework", "data", "ArchipelagoRE4R");
                Directory.CreateDirectory(gameDataDirectoryPath);
                var gameConnectionInfoPath = Path.Combine(gameDataDirectoryPath, "ap_connection.json");
                await File.WriteAllTextAsync(gameConnectionInfoPath, json, cancellationToken);
                Log($"Wrote AP connection info to {gameConnectionInfoPath} for the in-game Lua mod.");

                // The mod's session watermark/checked-set store lives in
                // reframework/data/ArchipelagoRE4R/bridge (game-relative; it
                // used to land at the game drive's root because REFramework
                // nils os.getenv). Pre-create it so the mod's first
                // json.dump_file cannot fail on a missing folder.
                Directory.CreateDirectory(Path.Combine(gameDataDirectoryPath, "bridge"));

                // Install identification for support triage: the mod logs this
                // stamp at boot, so a player's re2_framework_log.txt names the
                // exact launcher build and BioRand payload behind their install.
                var versionStampPath = Path.Combine(gameDataDirectoryPath, "version_stamp.json");
                var versionStampJson = JsonSerializer.Serialize(new
                {
                    launcher_version = GetLauncherVersion(),
                    payload_version = ReadPayloadVersion(),
                    installed_utc = _utcNow().UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss'Z'"),
                }, new JsonSerializerOptions { WriteIndented = true });
                await File.WriteAllTextAsync(versionStampPath, versionStampJson, cancellationToken);
                Log($"Wrote install version stamp to {versionStampPath}.");

                // The room's exact location-id set. The in-game client scouts from
                // this file; scouting ids the room does not have makes the server
                // drop the connection outright (live 2026-07-12: a 471-location
                // room vs the 476-id shipped map = a connect/disconnect loop every
                // ~1.5s whenever the AP getter fallback also came up empty).
                if (scoutResult.RoomLocationIds.Count > 0)
                {
                    var sortedIds = new long[scoutResult.RoomLocationIds.Count];
                    for (var i = 0; i < sortedIds.Length; i++)
                    {
                        sortedIds[i] = scoutResult.RoomLocationIds[i];
                    }
                    Array.Sort(sortedIds);
                    var roomLocationsPath = Path.Combine(gameDataDirectoryPath, "ap_room_locations.json");
                    var roomJson = JsonSerializer.Serialize(new
                    {
                        seed_name = scoutResult.SeedName,
                        slot_name = request.SlotName,
                        location_ids = sortedIds,
                    }, new JsonSerializerOptions { WriteIndented = true });
                    await File.WriteAllTextAsync(roomLocationsPath, roomJson, cancellationToken);
                    Log($"Wrote this room's {sortedIds.Length} location id(s) to {roomLocationsPath} for the in-game Lua mod.");
                }
            }
            return new ConnectionInfoWriteResult
            {
                FilePath = connectionInfoPath,
                ServerAddress = normalizedServer,
                SlotName = request.SlotName,
            };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new WorkflowException(
                WorkflowStep.WriteConnectionInfo,
                "The launcher could not write AP connection info into AppData. Check that the folder is writable and try again.",
                ex);
        }
    }

    private static string GetLauncherVersion()
    {
        var assembly = typeof(LaunchWorkflowService).Assembly;
        var informational = System.Reflection.CustomAttributeExtensions
            .GetCustomAttribute<System.Reflection.AssemblyInformationalVersionAttribute>(assembly)?
            .InformationalVersion;
        if (!string.IsNullOrWhiteSpace(informational))
        {
            return informational;
        }

        return assembly.GetName().Version?.ToString() ?? "unknown";
    }

    private static string ReadPayloadVersion()
    {
        // Best-effort: the stamp is diagnostics, never a workflow blocker.
        // The payload exe's own ProductVersion is the authority - it embeds
        // the fork commit ("1.0.0+d265c93...") and, unlike the provenance
        // text file, always ships (BIORAND_PROVENANCE.txt is repo-only; a
        // published install does not contain it).
        try
        {
            var payloadExePath = Path.Combine(
                AppContext.BaseDirectory, "assets", "BioRand", "biorand-re4r.exe");
            if (File.Exists(payloadExePath))
            {
                var version = System.Diagnostics.FileVersionInfo
                    .GetVersionInfo(payloadExePath).ProductVersion;
                if (!string.IsNullOrWhiteSpace(version))
                {
                    return version;
                }
            }

            // Dev-tree fallback: parse the provenance note.
            var provenancePath = Path.Combine(
                AppContext.BaseDirectory, "assets", "BIORAND_PROVENANCE.txt");
            if (File.Exists(provenancePath))
            {
                foreach (var line in File.ReadLines(provenancePath))
                {
                    var trimmed = line.Trim();
                    if (trimmed.StartsWith("Source commit:", StringComparison.OrdinalIgnoreCase))
                    {
                        var value = trimmed["Source commit:".Length..].Trim();
                        var firstToken = value.Split(' ', '\t')[0].Trim();
                        if (firstToken.Length > 0)
                        {
                            return firstToken;
                        }
                    }
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }

        return "unknown";
    }

    private static int ComputeDeterministicSeed(string seedName, string slotName, string manifestJson)
    {
        // Derived from the SCOUTED identity (seed name), never from the typed
        // server address: room addresses drift (added schemes, port churn on
        // archipelago.gg restarts) and must not change the physical world
        // (closes audit launchercore-12 / the review's volatile-address-keys).
        var payload = $"{seedName}\n{slotName}\n{manifestJson}";
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(payload));
        var seed = BitConverter.ToInt32(bytes, 0);
        return seed == int.MinValue ? 0 : Math.Abs(seed);
    }

    private static string ComputeSessionKey(LaunchWorkflowRequest request, ArchipelagoScoutSessionResult scoutResult)
    {
        return SessionKeyBuilder.ComputeSessionKey(scoutResult.SeedName, request.SlotName);
    }

    private static int? TryExtractPort(string normalizedServer)
    {
        if (!Uri.TryCreate(normalizedServer, UriKind.Absolute, out var uri))
        {
            return null;
        }

        return uri.IsDefaultPort ? null : uri.Port;
    }

    private async Task NotifyAsync(
        LaunchWorkflowRequest request,
        WorkflowStep step,
        string message)
    {
        Log(message);
        if (request.NotifyAsync is null)
        {
            return;
        }

        try
        {
            await request.NotifyAsync(message);
        }
        catch (Exception ex)
        {
            throw new WorkflowException(step, message, ex);
        }
    }

    private static void NotifyStepStarting(LaunchWorkflowRequest request, WorkflowStep step)
    {
        try
        {
            request.OnStepStarting?.Invoke(step);
        }
        catch
        {
            // Progress display must never break the workflow.
        }
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }

    private sealed record PrerequisiteValidationResult(
        StaticGameData StaticData,
        string StaticDataHash,
        string BioRandVersionDescriptor);

    private sealed record SessionDecisionResult(
        bool Cancelled = false,
        WorkflowStep? CancelledAtStep = null,
        string SessionKey = "",
        SessionRecord? SessionRecord = null,
        bool ResumeValidated = false);

    private sealed record ResumeValidationResult(bool IsValid, string Reason);
}
