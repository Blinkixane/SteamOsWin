using System.Windows;
using System.Diagnostics;
using SteamOsWin.Services;

namespace SteamOsWin;

public partial class App : System.Windows.Application
{
    protected override void OnStartup(System.Windows.StartupEventArgs e)
    {
        base.OnStartup(e);

        var forcedShellMode = e.Args.Any(argument =>
            string.Equals(argument, "--shell", StringComparison.OrdinalIgnoreCase));

        var userSessionMode = e.Args.Any(argument =>
            string.Equals(argument, "--user-session", StringComparison.OrdinalIgnoreCase));

        var dispatcherMode = e.Args.Any(argument =>
            string.Equals(argument, "--dispatcher", StringComparison.OrdinalIgnoreCase));

        var switchAgentMode = e.Args.Any(argument =>
            string.Equals(argument, "--switch-agent", StringComparison.OrdinalIgnoreCase));

        if (switchAgentMode)
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var agent = new SwitchAgentWindow();
            MainWindow = agent;
            agent.Show();
            return;
        }

        if (dispatcherMode && !forcedShellMode)
        {
            var startupMode = new BootModeDetector().DetectDispatcherMode();
            if (startupMode == StartupMode.NormalShell)
            {
                StartExplorerAndKeepAlive();
                return;
            }

            forcedShellMode = true;
        }

        var window = new MainWindow(forcedShellMode || userSessionMode, userSessionMode);
        MainWindow = window;
        window.Show();
    }

    private static void StartExplorerAndKeepAlive()
    {
        // Winlogon treats the configured shell as the lifetime of the user shell.
        // Keep this dispatcher alive after starting Explorer; exiting immediately
        // can leave only a file window without the desktop/taskbar.
        Current.ShutdownMode = ShutdownMode.OnExplicitShutdown;
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                UseShellExecute = true
            });
        }
        catch
        {
            // Winlogon remains available through the normal Windows recovery paths.
        }
    }
}
