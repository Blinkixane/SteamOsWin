using System.IO;
using System.Security.Principal;
using System.Text.Json;

namespace SteamOsWin.Services;

public enum StartupMode
{
    Dashboard,
    SteamShell,
    NormalShell
}

/// <summary>
/// Reads the mode belonging to the Windows installation that is currently running.
/// Each Windows installation (including a VHDX installation) carries its own marker.
/// This avoids relying on undocumented BCD state from an unprivileged shell process.
/// </summary>
public sealed class BootModeDetector
{
    public const string SteamMarker = "steam";
    public const string NormalMarker = "normal";

    public string MarkerPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "SteamOsWin",
        "mode.txt");

    public string UserModesPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "SteamOsWin",
        "user-modes.json");

    public StartupMode DetectDispatcherMode()
    {
        var configuredUserMode = TryReadUserMode();
        if (configuredUserMode.HasValue)
        {
            return configuredUserMode.Value;
        }

        try
        {
            if (File.ReadAllText(MarkerPath).Trim().Equals(SteamMarker, StringComparison.OrdinalIgnoreCase))
            {
                return StartupMode.SteamShell;
            }
        }
        catch (IOException)
        {
            // Missing or unavailable configuration safely falls back to normal Windows.
        }
        catch (UnauthorizedAccessException)
        {
            // A restricted configuration safely falls back to normal Windows.
        }

        return StartupMode.NormalShell;
    }

    private StartupMode? TryReadUserMode()
    {
        try
        {
            if (!File.Exists(UserModesPath))
            {
                return null;
            }

            using var document = JsonDocument.Parse(File.ReadAllText(UserModesPath));
            var root = document.RootElement;
            var currentUserName = Environment.UserName;
            var currentSid = WindowsIdentity.GetCurrent().User?.Value;

            if (root.TryGetProperty("users", out var users) && users.ValueKind == JsonValueKind.Array)
            {
                foreach (var user in users.EnumerateArray())
                {
                    var userName = TryGetString(user, "userName");
                    var sid = TryGetString(user, "sid");
                    if (!string.Equals(userName, currentUserName, StringComparison.OrdinalIgnoreCase) &&
                        !(!string.IsNullOrWhiteSpace(currentSid) && string.Equals(sid, currentSid, StringComparison.OrdinalIgnoreCase)))
                    {
                        continue;
                    }

                    return ParseMode(TryGetString(user, "mode"));
                }
            }

            if (root.TryGetProperty("defaultMode", out var defaultMode))
            {
                return ParseMode(defaultMode.GetString());
            }
        }
        catch (IOException)
        {
            // A missing or unavailable configuration safely falls back to the marker.
        }
        catch (UnauthorizedAccessException)
        {
            // A restricted configuration safely falls back to the marker.
        }
        catch (JsonException)
        {
            // A malformed configuration must never prevent a normal Windows login.
        }

        return null;
    }

    private static StartupMode ParseMode(string? mode)
    {
        return string.Equals(mode, SteamMarker, StringComparison.OrdinalIgnoreCase)
            ? StartupMode.SteamShell
            : StartupMode.NormalShell;
    }

    private static string? TryGetString(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;
    }
}
