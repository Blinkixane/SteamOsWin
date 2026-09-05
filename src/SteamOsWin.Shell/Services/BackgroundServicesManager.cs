using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace SteamOsWin.Services;

public sealed class BackgroundProcessDefinition
{
    public string Id { get; set; } = string.Empty;
    public string[] ProcessNames { get; set; } = [];
    public string? CommandLineContains { get; set; }
    public string Executable { get; set; } = string.Empty;
    public string? Arguments { get; set; }
    public string? WorkingDirectory { get; set; }
    public bool RestartIfMissing { get; set; } = true;
}

public sealed class BackgroundServiceDefinition
{
    public string Id { get; set; } = string.Empty;
    public string ServiceName { get; set; } = string.Empty;
    public bool EnsureRunning { get; set; } = true;
}

public sealed class BackgroundServicesConfiguration
{
    public List<BackgroundProcessDefinition> Processes { get; set; } = [];
    public List<BackgroundServiceDefinition> Services { get; set; } = [];
}

public sealed record BackgroundServicesStatus(string Message, int ProcessesStarted, int ServicesStarted);

/// <summary>
/// Keeps the non-Steam Windows components requested by the user alive while the
/// Explorer shell is replaced. It never stops a process or service on exit.
/// </summary>
public sealed class BackgroundServicesManager
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip
    };

    private readonly BackgroundServicesConfiguration _configuration;
    private readonly string _logPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SteamOsWin",
        "background-services.log");

    public BackgroundServicesManager()
    {
        _configuration = LoadConfiguration();
    }

    public BackgroundServicesStatus EnsureAll()
    {
        var processesStarted = 0;
        var servicesStarted = 0;
        var details = new List<string>();

        foreach (var service in _configuration.Services)
        {
            if (!service.EnsureRunning || IsServiceRunning(service.ServiceName))
            {
                continue;
            }

            if (StartService(service.ServiceName))
            {
                servicesStarted++;
                details.Add($"service {service.ServiceName}");
            }
        }

        foreach (var process in _configuration.Processes)
        {
            if (!process.RestartIfMissing || IsProcessRunning(process))
            {
                continue;
            }

            if (StartProcess(process))
            {
                processesStarted++;
                details.Add($"app {process.Id}");
            }
        }

        if (details.Count > 0)
        {
            Log($"Relancés : {string.Join(", ", details)}");
        }

        var configuredServices = _configuration.Services.Count;
        var configuredProcesses = _configuration.Processes.Count;
        var message = $"Services préservés : {configuredServices} services, {configuredProcesses} applications";
        if (details.Count > 0)
        {
            message += $" — {details.Count} relancé(s)";
        }

        return new BackgroundServicesStatus(message, processesStarted, servicesStarted);
    }

    private BackgroundServicesConfiguration LoadConfiguration()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "background-services.json"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SteamOsWin", "background-services.json")
        };

        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                if (File.Exists(candidate))
                {
                    var json = File.ReadAllText(candidate);
                    return JsonSerializer.Deserialize<BackgroundServicesConfiguration>(json, JsonOptions)
                        ?? new BackgroundServicesConfiguration();
                }
            }
            catch (Exception exception) when (exception is IOException or JsonException)
            {
                Log($"Configuration ignorée ({candidate}) : {exception.Message}");
            }
        }

        return new BackgroundServicesConfiguration();
    }

    private static bool IsProcessRunning(BackgroundProcessDefinition definition)
    {
        var names = definition.ProcessNames
            .Select(name => Path.GetFileNameWithoutExtension(name))
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        if (names.Count == 0)
        {
            return false;
        }

        try
        {
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    if (!names.Contains(process.ProcessName))
                    {
                        continue;
                    }

                    if (string.IsNullOrWhiteSpace(definition.CommandLineContains))
                    {
                        process.Dispose();
                        return true;
                    }

                    var commandLine = TryGetCommandLine(process.Id);
                    if (commandLine?.Contains(definition.CommandLineContains, StringComparison.OrdinalIgnoreCase) == true)
                    {
                        process.Dispose();
                        return true;
                    }
                }
                catch
                {
                    // A protected/system process can disappear while it is inspected.
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
        catch
        {
            // Process enumeration is best effort; it must not block Steam.
        }

        return false;
    }

    private static string? TryGetCommandLine(int processId)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -NonInteractive -Command \"(Get-CimInstance Win32_Process -Filter 'ProcessId={processId}').CommandLine\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            });

            if (process is null)
            {
                return null;
            }

            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(1000);
            return output;
        }
        catch
        {
            return null;
        }
    }

    private static bool StartProcess(BackgroundProcessDefinition definition)
    {
        var executable = Environment.ExpandEnvironmentVariables(definition.Executable);
        var workingDirectory = string.IsNullOrWhiteSpace(definition.WorkingDirectory)
            ? null
            : Environment.ExpandEnvironmentVariables(definition.WorkingDirectory);

        if (!File.Exists(executable))
        {
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = executable,
                Arguments = definition.Arguments ?? string.Empty,
                WorkingDirectory = Directory.Exists(workingDirectory)
                    ? workingDirectory
                    : Path.GetDirectoryName(executable),
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            });
            return true;
        }
        catch
        {
            return false;
        }
    }

    private bool IsServiceRunning(string serviceName)
    {
        var result = RunSc("query", serviceName);
        return result.ExitCode == 0 && result.Output.Contains("RUNNING", StringComparison.OrdinalIgnoreCase);
    }

    private bool StartService(string serviceName)
    {
        var result = RunSc("start", serviceName);
        if (result.ExitCode == 0)
        {
            return true;
        }

        Log($"Service {serviceName} non démarré : {result.Output.Trim()}");
        return false;
    }

    private static (int ExitCode, string Output) RunSc(params string[] arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "sc.exe",
                Arguments = string.Join(" ", arguments.Select(QuoteArgument)),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            });

            if (process is null)
            {
                return (-1, "sc.exe introuvable");
            }

            var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
            process.WaitForExit(2000);
            return (process.ExitCode, output);
        }
        catch (Exception exception)
        {
            return (-1, exception.Message);
        }
    }

    private static string QuoteArgument(string argument)
    {
        return argument.Contains(' ') ? $"\"{argument.Replace("\"", "\\\"")}\"" : argument;
    }

    private void Log(string message)
    {
        try
        {
            var directory = Path.GetDirectoryName(_logPath);
            if (directory is not null)
            {
                Directory.CreateDirectory(directory);
            }

            File.AppendAllText(_logPath, $"[{DateTimeOffset.Now:O}] {message}{Environment.NewLine}");
        }
        catch
        {
            // Logging must never prevent the gaming shell from starting.
        }
    }
}
