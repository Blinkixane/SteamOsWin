using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace SteamOsWin.Services;

public sealed record SessionSwitchResult(bool Success, string Message)
{
    public static SessionSwitchResult Ok(string message) => new(true, message);
    public static SessionSwitchResult Fail(string message) => new(false, message);
}

/// <summary>
/// Requests a switch to the other already-logged-on local account.
/// The privileged part is deliberately isolated in a pre-installed scheduled
/// task. The interactive user process never calls tscon or session APIs directly.
/// </summary>
public static class SessionSwitcher
{
    public const string TaskName = @"\SteamOsWin\SessionSwitch";
    private const string ConfigPath = @"C:\ProgramData\SteamOsWin\session-switch.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public static SessionSwitchResult Request()
    {
        try
        {
            var configuration = LoadConfiguration();
            var currentUser = Environment.UserName;
            var targetUser = ResolveTargetUser(currentUser, configuration);
            if (targetUser is null)
            {
                return SessionSwitchResult.Fail(
                    $"Aucun compte cible configure pour l'utilisateur '{currentUser}'.");
            }

            if (string.Equals(configuration.SwitchMode, "logoff", StringComparison.OrdinalIgnoreCase))
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe",
                    Arguments = "/c shutdown.exe /l",
                    UseShellExecute = false,
                    CreateNoWindow = true
                });

                return SessionSwitchResult.Ok(
                    $"Session fermee. Connecte-toi maintenant avec le mot de passe de '{targetUser}'.");
            }

            var targetSession = FindLoggedOnSession(targetUser);
            if (targetSession is null)
            {
                return SessionSwitchResult.Fail(
                    $"'{targetUser}' doit avoir ete connecte au moins une fois depuis le demarrage du PC.");
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "schtasks.exe",
                Arguments = $"/c schtasks.exe /run /tn \"{TaskName}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return SessionSwitchResult.Fail("Impossible de demarrer le gestionnaire de sessions.");
            }

            process.WaitForExit(3000);
            if (!process.HasExited || process.ExitCode != 0)
            {
                var error = process.HasExited
                    ? process.StandardError.ReadToEnd().Trim()
                    : "Le gestionnaire de sessions ne repond pas.";
                return SessionSwitchResult.Fail(
                    string.IsNullOrWhiteSpace(error)
                        ? "La bascule n'a pas pu etre demandee. Installe d'abord le gestionnaire de sessions."
                        : error);
            }

            return SessionSwitchResult.Ok(
                $"Bascule vers {targetUser} demandee. La session actuelle sera deconnectee et restera disponible pour le retour.");
        }
        catch (Exception exception)
        {
            return SessionSwitchResult.Fail($"Bascule impossible : {exception.Message}");
        }
    }

    private static SessionSwitchConfiguration LoadConfiguration()
    {
        if (!File.Exists(ConfigPath))
        {
            return new SessionSwitchConfiguration();
        }

        var json = File.ReadAllText(ConfigPath);
        return JsonSerializer.Deserialize<SessionSwitchConfiguration>(json, JsonOptions)
            ?? new SessionSwitchConfiguration();
    }

    private static string? ResolveTargetUser(string currentUser, SessionSwitchConfiguration configuration)
    {
        if (currentUser.Equals(configuration.NormalUserName, StringComparison.OrdinalIgnoreCase))
        {
            return configuration.GamingUserName;
        }

        if (currentUser.Equals(configuration.GamingUserName, StringComparison.OrdinalIgnoreCase))
        {
            return configuration.NormalUserName;
        }

        return null;
    }

    private static WtsSessionRecord? FindLoggedOnSession(string userName)
    {
        return WtsNative.Enumerate()
            .Where(session =>
                session.UserName.Equals(userName, StringComparison.OrdinalIgnoreCase) &&
                session.State is WtsSessionState.Active or WtsSessionState.Disconnected)
            .OrderBy(session => session.State == WtsSessionState.Disconnected ? 0 : 1)
            .ThenBy(session => session.Id)
            .FirstOrDefault();
    }
}

public sealed class SessionSwitchConfiguration
{
    public string NormalUserName { get; set; } = "Euxane";
    public string GamingUserName { get; set; } = "SteamGaming";
    public string SwitchMode { get; set; } = "fast";
}

public enum WtsSessionState
{
    Active = 0,
    Connected = 1,
    ConnectQuery = 2,
    Shadow = 3,
    Disconnected = 4,
    Idle = 5,
    Listen = 6,
    Reset = 7,
    Down = 8,
    Init = 9
}

public sealed record WtsSessionRecord(int Id, string WinStationName, string UserName, WtsSessionState State);

internal static class WtsNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WtsSessionInfo
    {
        public int SessionId;
        public IntPtr WinStationName;
        public WtsSessionState State;
    }

    private enum WtsInfoClass
    {
        UserName = 5
    }

    [DllImport("wtsapi32.dll", EntryPoint = "WTSEnumerateSessionsW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumerateSessions(
        IntPtr server,
        int reserved,
        int version,
        out IntPtr sessionInfo,
        out int count);

    [DllImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QuerySessionInformation(
        IntPtr server,
        int sessionId,
        WtsInfoClass informationClass,
        out IntPtr buffer,
        out int bytesReturned);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);

    public static IReadOnlyList<WtsSessionRecord> Enumerate()
    {
        if (!EnumerateSessions(IntPtr.Zero, 0, 1, out var buffer, out var count))
        {
            return [];
        }

        try
        {
            var itemSize = Marshal.SizeOf<WtsSessionInfo>();
            var result = new List<WtsSessionRecord>(count);
            for (var index = 0; index < count; index++)
            {
                var item = Marshal.PtrToStructure<WtsSessionInfo>(buffer + index * itemSize);
                var station = Marshal.PtrToStringUni(item.WinStationName) ?? string.Empty;
                result.Add(new WtsSessionRecord(item.SessionId, station, QueryUserName(item.SessionId), item.State));
            }

            return result;
        }
        finally
        {
            WTSFreeMemory(buffer);
        }
    }

    private static string QueryUserName(int sessionId)
    {
        if (!QuerySessionInformation(IntPtr.Zero, sessionId, WtsInfoClass.UserName, out var buffer, out _))
        {
            return string.Empty;
        }

        try
        {
            return Marshal.PtrToStringUni(buffer) ?? string.Empty;
        }
        finally
        {
            WTSFreeMemory(buffer);
        }
    }
}
