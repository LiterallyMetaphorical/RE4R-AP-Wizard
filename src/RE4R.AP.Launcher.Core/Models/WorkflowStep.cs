namespace RE4R.AP.Launcher.Core.Models;

public enum WorkflowStep
{
    Unknown = -1,
    ValidateSettings = 0,
    CheckSetup = 1,
    ScoutApServer = 2,
    CheckExistingSession = 3,
    ValidateResume = 4,
    BuildManifest = 5,
    RunBioRandGeneration = 6,
    InstallPatchFiles = 7,
    InstallLuaModFiles = 8,
    SaveFileSafetyWarning = 9,
    WriteSessionRecord = 10,
    WriteConnectionInfo = 11,
}
