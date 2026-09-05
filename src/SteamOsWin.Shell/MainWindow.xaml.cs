using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;
using Forms = System.Windows.Forms;
using SteamOsWin.Services;
using WpfApplication = System.Windows.Application;
using WpfMessageBox = System.Windows.MessageBox;
using WpfMessageBoxButton = System.Windows.MessageBoxButton;
using WpfMessageBoxImage = System.Windows.MessageBoxImage;
using WpfPoint = System.Windows.Point;

namespace SteamOsWin;

public partial class MainWindow : Window
{
    private readonly bool _shellMode;
    private readonly bool _userSessionMode;
    private readonly SteamProcessService _steam = new();
    private readonly SteamSessionManager _session = new();
    private List<DisplayInfo> _displays = [];
    private bool _hasLaunchedSteam;
    private CancellationTokenSource? _sessionCancellation;
    private GlobalHotKey? _exitHotKey;
    private bool _switchInProgress;
    private bool _steamSessionEventsAttached;
    private bool _systemSessionEventsAttached;

    public MainWindow(bool shellMode, bool userSessionMode = false)
    {
        InitializeComponent();
        _shellMode = shellMode;
        _userSessionMode = userSessionMode;
        Loaded += MainWindow_Loaded;
        SourceInitialized += MainWindow_SourceInitialized;
        Closing += MainWindow_Closing;
    }

    private void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        ConfigureDisplays();
        SteamPathText.Text = _steam.SteamPath is { } path
            ? $"Steam détecté : {path}"
            : "Steam non détecté dans les chemins standards";

        if (_shellMode)
        {
            SessionText.Text = "SteamShell — mode dédié";
            StatusText.Text = "Mode shell : Steam va être lancé";
            ShowInTaskbar = false;
            Hide();
            if (_userSessionMode)
            {
                StopCurrentSessionExplorer();
            }
            StartDedicatedSession();
        }
        else
        {
            StatusText.Text = "Prototype — aucun changement système";
        }
    }

    private void MainWindow_SourceInitialized(object? sender, EventArgs e)
    {
        if (_shellMode)
        {
            _exitHotKey = new GlobalHotKey(new WindowInteropHelper(this).Handle);
            _exitHotKey.Pressed += ExitHotKey_Pressed;
            if (!_exitHotKey.IsRegistered)
            {
                StatusText.Text = "Raccourci Ctrl + Alt + W indisponible (code Windows " +
                    _exitHotKey.RegistrationError + ")";
            }

            SystemEvents.SessionSwitch += SystemEvents_SessionSwitch;
            _systemSessionEventsAttached = true;
        }
    }

    private void ConfigureDisplays()
    {
        _displays = Forms.Screen.AllScreens
            .Select((screen, index) => new DisplayInfo(
                screen,
                $"Écran {index + 1}{(screen.Primary ? " · principal" : string.Empty)}",
                $"{screen.Bounds.Width} × {screen.Bounds.Height}"))
            .ToList();

        DisplaySelector.ItemsSource = _displays;
        DisplaySelector.DisplayMemberPath = nameof(DisplayInfo.Label);
        if (_displays.Count > 0)
        {
            DisplaySelector.SelectedIndex = _displays.FindIndex(display => display.Screen.Primary);
            if (DisplaySelector.SelectedIndex < 0)
            {
                DisplaySelector.SelectedIndex = 0;
            }
        }
    }

    private void DisplaySelector_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (DisplaySelector.SelectedItem is DisplayInfo display && IsLoaded)
        {
            MoveToDisplay(display.Screen);
            StatusText.Text = $"Affichage actif : {display.Label}";
        }
    }

    private void MoveToDisplay(Forms.Screen screen)
    {
        // Screen.Bounds are physical pixels. Convert them to WPF DIPs for mixed-DPI setups.
        var source = PresentationSource.FromVisual(this);
        var fromDevice = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var topLeft = fromDevice.Transform(new WpfPoint(screen.Bounds.Left, screen.Bounds.Top));
        var bottomRight = fromDevice.Transform(new WpfPoint(screen.Bounds.Right, screen.Bounds.Bottom));

        WindowState = WindowState.Normal;
        Left = topLeft.X;
        Top = topLeft.Y;
        Width = bottomRight.X - topLeft.X;
        Height = bottomRight.Y - topLeft.Y;
        WindowState = WindowState.Maximized;
    }

    private void LaunchSteam_Click(object sender, RoutedEventArgs e) => LaunchSteam();

    private void LaunchSteam()
    {
        if (_hasLaunchedSteam)
        {
            StatusText.Text = "Steam est déjà demandé pour cette session";
            return;
        }

        var process = _session.LaunchOnce(out var error);
        if (process is null)
        {
            StatusText.Text = error ?? "Steam n'a pas pu être lancé";
            WpfMessageBox.Show(error ?? "Steam n'a pas pu être lancé.", "SteamOS-Win", WpfMessageBoxButton.OK, WpfMessageBoxImage.Warning);
            return;
        }

        _hasLaunchedSteam = true;
        StatusText.Text = "Steam lancé en Gamepad UI";
    }

    private async void StartDedicatedSession()
    {
        if (!_steamSessionEventsAttached)
        {
            _session.StateChanged += Session_StateChanged;
            _steamSessionEventsAttached = true;
        }
        _sessionCancellation = new CancellationTokenSource();

        try
        {
            await _session.RunAsync(_sessionCancellation.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected when leaving the dedicated session.
        }
    }

    private void Session_StateChanged(object? sender, SteamSessionStateChangedEventArgs e)
    {
        void UpdateView()
        {
            StatusText.Text = e.Message;
            SessionText.Text = e.State switch
            {
                SteamSessionState.Running => "SteamShell — Steam actif",
                SteamSessionState.Restarting => "SteamShell — récupération",
                SteamSessionState.Error => "SteamShell — erreur — récupération manuelle requise",
                _ => "SteamShell — démarrage"
            };

            if (_shellMode && e.State == SteamSessionState.Error)
            {
                Show();
                WindowState = WindowState.Maximized;
                Activate();
            }
        }

        if (Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
        {
            return;
        }

        if (Dispatcher.CheckAccess())
        {
            UpdateView();
        }
        else
        {
            Dispatcher.BeginInvoke(UpdateView);
        }
    }

    private void ExitHotKey_Pressed(object? sender, EventArgs e)
    {
        Dispatcher.Invoke(RequestAccountSwitch);
    }

    private void RequestAccountSwitch()
    {
        if (_switchInProgress)
        {
            return;
        }

        _switchInProgress = true;
        StatusText.Text = "Preparation du changement de session...";

        // Ask Steam to close gracefully, but do not wait indefinitely. The
        // privileged broker transfers the other session first and disconnects
        // this session only after that transfer succeeds.
        _session.RequestStop();
        _sessionCancellation?.Cancel();
        _session.ShutdownSteam(out _);

        var switchResult = SessionSwitcher.Request();
        if (!switchResult.Success)
        {
            _switchInProgress = false;
            StatusText.Text = switchResult.Message;
            WpfMessageBox.Show(switchResult.Message, "Changement de session", WpfMessageBoxButton.OK, WpfMessageBoxImage.Information);
            return;
        }

        StatusText.Text = switchResult.Message;
        Hide();
        _ = ReleaseSwitchGuardAfterDelayAsync();
    }

    private void SystemEvents_SessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (!_shellMode || e.Reason is not (SessionSwitchReason.ConsoleConnect or SessionSwitchReason.SessionUnlock))
        {
            return;
        }

        Dispatcher.BeginInvoke(ResumeDedicatedSession);
    }

    private void ResumeDedicatedSession()
    {
        if (!_shellMode || !_switchInProgress)
        {
            return;
        }

        _switchInProgress = false;
        _sessionCancellation?.Dispose();
        _sessionCancellation = null;
        _hasLaunchedSteam = false;
        StatusText.Text = "Session gaming reprise — relance de Steam...";
        StartDedicatedSession();
    }

    private async Task ReleaseSwitchGuardAfterDelayAsync()
    {
        await Task.Delay(TimeSpan.FromSeconds(5));
        _switchInProgress = false;
    }

    private static void StopCurrentSessionExplorer()
    {
        var sessionId = Process.GetCurrentProcess().SessionId;
        foreach (var explorer in Process.GetProcessesByName("explorer"))
        {
            try
            {
                if (explorer.SessionId == sessionId && explorer.Id != Environment.ProcessId)
                {
                    explorer.Kill(entireProcessTree: true);
                }
            }
            catch
            {
                // Explorer may already be exiting or may belong to another session.
            }
            finally
            {
                explorer.Dispose();
            }
        }
    }

    private void Navigation_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.Button button)
        {
            return;
        }

        var (title, subtitle) = button.Tag?.ToString() switch
        {
            "recent" => ("Jeux récents", "Reprendre rapidement les dernières sessions."),
            "downloads" => ("Téléchargements", "État des téléchargements Steam."),
            "display" => ("Affichage", "Le mode SteamOS-Win utilise l'écran choisi à sa résolution native."),
            "controller" => ("Contrôleurs", "Steam Input sera la couche de contrôle principale."),
            "power" => ("Alimentation", "Redémarrer, arrêter ou quitter le mode gaming en sécurité."),
            _ => ("Bibliothèque", "Une interface pensée pour jouer à la manette, sans étirer l'affichage.")
        };

        PageTitle.Text = title;
        PageSubtitle.Text = subtitle;
        StatusText.Text = $"Section : {title}";
    }

    private void Exit_Click(object sender, RoutedEventArgs e)
    {
        if (_shellMode)
        {
            RequestAccountSwitch();
            return;
        }

        var result = WpfMessageBox.Show(
            "Fermer le prototype SteamOS-Win ? Steam continuera de fonctionner s'il est déjà ouvert.",
            "Quitter",
            WpfMessageBoxButton.YesNo,
            WpfMessageBoxImage.Question);

        if (result == MessageBoxResult.Yes)
        {
            WpfApplication.Current.Shutdown();
        }
    }

    private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_systemSessionEventsAttached)
        {
            SystemEvents.SessionSwitch -= SystemEvents_SessionSwitch;
        }
        _exitHotKey?.Dispose();
        _session.RequestStop();
        _sessionCancellation?.Cancel();
        _sessionCancellation?.Dispose();
        _session.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    private void Window_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.F1)
        {
            WpfMessageBox.Show(
                "V2 : interface adaptative, session Steam supervisée et retour bureau sécurisé.\n\n" +
                "Raccourci global : Ctrl + Alt + W pour changer de session.",
                "SteamOS-Win — état du prototype",
                WpfMessageBoxButton.OK,
                WpfMessageBoxImage.Information);
            e.Handled = true;
        }
    }

    private sealed record DisplayInfo(Forms.Screen Screen, string Name, string Resolution)
    {
        public string Label => $"{Name} — {Resolution}";
    }
}
