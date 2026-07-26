using Avalonia;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }

        return LinuxLauncher.RunAsync(args).GetAwaiter().GetResult();
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace();
}

internal static class LinuxLauncher
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length == 0 || args[0] is "-h" or "--help" or "help")
        {
            PrintHelp();
            return 0;
        }

        var appDataPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "RE4R-AP");
        var service = new ArchipelagoInstallationService(appDataPath);

        try
        {
            return args[0] switch
            {
                "inspect" when args.Length == 2 => Inspect(service, args[1]),
                "install-world" when args.Length == 2 => await InstallWorldAsync(service, args[1]),
                "prepare" when args.Length >= 3 => await PrepareAsync(service, args[1], args[2..]),
                "output" when args.Length == 2 => FindOutput(service, args[1]),
                _ => InvalidArguments(),
            };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            Console.Error.WriteLine($"error: {ex.Message}");
            return 1;
        }
    }

    private static int Inspect(ArchipelagoInstallationService service, string rootPath)
    {
        var inspection = service.Inspect(rootPath);
        if (!inspection.RootExists)
        {
            Console.Error.WriteLine($"Archipelago folder not found: {rootPath}");
            return 1;
        }

        if (!inspection.GeneratorFound)
        {
            Console.Error.WriteLine(
                $"No supported generator found. Expected one of: {string.Join(", ", ArchipelagoInstallationService.GeneratorFileNames)}");
            return 1;
        }

        Console.WriteLine($"Archipelago: {inspection.RootPath}");
        Console.WriteLine($"Generator: {inspection.GeneratorPath}");
        Console.WriteLine(inspection.HasVersion
            ? $"Version: {inspection.DetectedVersion}"
            : "Version: unavailable (accepted)");
        return 0;
    }

    private static async Task<int> InstallWorldAsync(
        ArchipelagoInstallationService service,
        string rootPath)
    {
        if (Inspect(service, rootPath) != 0)
        {
            return 1;
        }

        var destination = await service.CopyApworldAsync(rootPath);
        Console.WriteLine($"Installed RE4R.apworld: {destination}");
        return 0;
    }

    private static async Task<int> PrepareAsync(
        ArchipelagoInstallationService service,
        string rootPath,
        IReadOnlyList<string> yamlPaths)
    {
        if (await InstallWorldAsync(service, rootPath) != 0)
        {
            return 1;
        }

        var entries = new List<CollectedYamlDraftEntry>();
        foreach (var yamlPath in yamlPaths)
        {
            var extension = Path.GetExtension(yamlPath);
            if (!File.Exists(yamlPath)
                || (!extension.Equals(".yaml", StringComparison.OrdinalIgnoreCase)
                    && !extension.Equals(".yml", StringComparison.OrdinalIgnoreCase)))
            {
                Console.Error.WriteLine($"Invalid YAML file: {yamlPath}");
                return 1;
            }

            var cached = await service.CacheCollectedYamlAsync(yamlPath);
            entries.Add(new CollectedYamlDraftEntry
            {
                CachePath = cached.CachePath,
                FileName = cached.FileName,
            });
        }

        var copied = await service.CopyCachedYamlsToPlayersAsync(entries, rootPath);
        Console.WriteLine($"Copied {copied} YAML file(s) to {ArchipelagoInstallationService.GetPlayersPath(rootPath)}");
        Console.WriteLine($"Run the Archipelago generator: {service.Inspect(rootPath).GeneratorPath}");
        return 0;
    }

    private static int FindOutput(ArchipelagoInstallationService service, string rootPath)
    {
        var output = service.FindNewestOutputZip(rootPath);
        if (output is null)
        {
            Console.Error.WriteLine($"No AP_*.zip found in {ArchipelagoInstallationService.GetOutputPath(rootPath)}");
            return 1;
        }

        Console.WriteLine(output.FullName);
        return 0;
    }

    private static int InvalidArguments()
    {
        Console.Error.WriteLine("Invalid arguments. Run with --help.");
        return 2;
    }

    private static void PrintHelp()
    {
        Console.WriteLine(
            """
            RE4R Archipelago Launcher

            Usage:
              re4r-ap-launcher inspect <archipelago-root>
              re4r-ap-launcher install-world <archipelago-root>
              re4r-ap-launcher prepare <archipelago-root> <player.yaml> [...]
              re4r-ap-launcher output <archipelago-root>

            Accepted generators:
              ArchipelagoGenerate.exe, ArchipelagoGenerate, Generate.py
            """);
    }
}
