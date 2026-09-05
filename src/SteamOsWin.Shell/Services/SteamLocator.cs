using System.IO;
using System.Security;
using Microsoft.Win32;

namespace SteamOsWin.Services;

public sealed class SteamLocator
{
    public string? FindSteamExecutable()
    {
        var candidates = new List<string>();

        AddRegistryPath(candidates, RegistryHive.CurrentUser, RegistryView.Registry64);
        AddRegistryPath(candidates, RegistryHive.CurrentUser, RegistryView.Registry32);
        AddRegistryPath(candidates, RegistryHive.LocalMachine, RegistryView.Registry64);
        AddRegistryPath(candidates, RegistryHive.LocalMachine, RegistryView.Registry32);

        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        candidates.Add(Path.Combine(programFilesX86, "Steam", "steam.exe"));
        candidates.Add(Path.Combine(programFiles, "Steam", "steam.exe"));

        return candidates
            .Where(File.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault();
    }

    private static void AddRegistryPath(ICollection<string> candidates, RegistryHive hive, RegistryView view)
    {
        try
        {
            using var baseKey = RegistryKey.OpenBaseKey(hive, view);
            using var key = baseKey.OpenSubKey(@"Software\Valve\Steam");
            var installPath = key?.GetValue("SteamPath") as string;

            if (!string.IsNullOrWhiteSpace(installPath))
            {
                candidates.Add(Path.Combine(installPath, "steam.exe"));
            }
        }
        catch (SecurityException)
        {
            // A restricted registry view should not prevent checking the other candidates.
        }
        catch (IOException)
        {
            // A transient registry problem should not prevent the launcher from starting.
        }
    }
}
