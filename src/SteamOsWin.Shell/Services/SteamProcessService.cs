using System.ComponentModel;
using System.Diagnostics;
using System.IO;

namespace SteamOsWin.Services;

public sealed class SteamProcessService
{
    private readonly SteamLocator _locator = new();

    public string? SteamPath => _locator.FindSteamExecutable();

    public Process? LaunchGamepadUi(out string? error)
    {
        error = null;
        var steamPath = SteamPath;

        if (steamPath is null)
        {
            error = "Steam est introuvable. Installe Steam ou ajoute son chemin dans la configuration.";
            return null;
        }

        try
        {
            return Process.Start(new ProcessStartInfo
            {
                FileName = steamPath,
                Arguments = "-gamepadui",
                WorkingDirectory = Path.GetDirectoryName(steamPath),
                UseShellExecute = true
            });
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            error = $"Steam n'a pas pu être lancé : {exception.Message}";
            return null;
        }
    }

    public bool Shutdown(out string? error)
    {
        error = null;
        var steamPath = SteamPath;

        if (steamPath is null)
        {
            error = "Steam est introuvable.";
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = steamPath,
                Arguments = "-shutdown",
                WorkingDirectory = Path.GetDirectoryName(steamPath),
                UseShellExecute = true
            });
            return true;
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            error = $"Steam n'a pas pu être arrêté : {exception.Message}";
            return false;
        }
    }

    public static bool IsSteamRunning()
    {
        try
        {
            foreach (var process in Process.GetProcessesByName("steam"))
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Dispose();
                        return true;
                    }
                }
                catch
                {
                    // A process that cannot be inspected is not considered active.
                }

                process.Dispose();
            }
        }
        catch
        {
            // Process enumeration can fail during logoff or shutdown.
        }

        return false;
    }
}
