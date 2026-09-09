using System.Runtime.CompilerServices;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Tests;

/// <summary>
/// The manifest tests run against the bundled static data, so they check the
/// counts the launcher really ships with. The file is found by walking up from
/// the test binary to the repository root, which keeps the tests independent
/// of the build configuration folder they run from.
/// </summary>
internal static class RepoPaths
{
    public static string AssetsData { get; } = FindAssetsData();

    /// <summary>
    /// The BioRand option catalog reads from a fixed path beside the binary
    /// unless told otherwise; point it at the bundled copy before any test
    /// can touch it (the manifest build sanitises options on every call).
    /// </summary>
    [ModuleInitializer]
    internal static void PointTheCatalogAtTheBundle()
    {
        BioRandOptionCatalog.AssetsDataDirectoryPathOverride = AssetsData;
    }

    private static string FindAssetsData()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, "assets", "Data");
            if (File.Exists(Path.Combine(candidate, "re4r_ap_static.json")))
            {
                return candidate;
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException(
            $"assets/Data/re4r_ap_static.json was not found above {AppContext.BaseDirectory}.");
    }
}
