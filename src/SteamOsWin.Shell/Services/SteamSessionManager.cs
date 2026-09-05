using System.Diagnostics;

namespace SteamOsWin.Services;

public enum SteamSessionState
{
    Stopped,
    Starting,
    Running,
    Restarting,
    Error
}

public sealed class SteamSessionStateChangedEventArgs(SteamSessionState state, string message) : EventArgs
{
    public SteamSessionState State { get; } = state;
    public string Message { get; } = message;
}

/// <summary>
/// Owns the Steam process lifecycle for the dedicated shell.
/// Steam.exe can exit immediately when an existing Steam instance receives the
/// command, so the manager observes the Steam process family instead of relying
/// only on the launcher process returned by Process.Start.
/// </summary>
public sealed class SteamSessionManager : IAsyncDisposable
{
    private readonly SteamProcessService _steam = new();
    private readonly BackgroundServicesManager _background = new();
    private readonly object _sync = new();
    private CancellationTokenSource? _sessionCancellation;
    private bool _stopRequested;
    private bool _disposed;

    public event EventHandler<SteamSessionStateChangedEventArgs>? StateChanged;

    public SteamSessionState State { get; private set; } = SteamSessionState.Stopped;

    public Task RunAsync(CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _stopRequested = false;
            _sessionCancellation?.Cancel();
            _sessionCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            return RunCoreAsync(_sessionCancellation.Token);
        }
    }

    public void RequestStop()
    {
        lock (_sync)
        {
            _stopRequested = true;
            _sessionCancellation?.Cancel();
        }

        Publish(SteamSessionState.Stopped, "Session Steam arrêtée");
    }

    public Process? LaunchOnce(out string? error) => _steam.LaunchGamepadUi(out error);

    public bool ShutdownSteam(out string? error) => _steam.Shutdown(out error);

    private async Task RunCoreAsync(CancellationToken cancellationToken)
    {
        var backgroundStatus = _background.EnsureAll();
        Publish(SteamSessionState.Starting, backgroundStatus.Message);

        while (!cancellationToken.IsCancellationRequested)
        {
            Publish(_stopRequested ? SteamSessionState.Stopped : SteamSessionState.Starting,
                "Démarrage de Steam en Gamepad UI...");

            var process = LaunchOnce(out var error);
            process?.Dispose();
            if (process is null && !SteamProcessService.IsSteamRunning())
            {
                Publish(SteamSessionState.Error, error ?? "Steam n'a pas pu être lancé");
                return;
            }

            if (!await WaitUntilRunningAsync(cancellationToken).ConfigureAwait(false))
            {
                return;
            }

            Publish(SteamSessionState.Running, "Steam est actif — session dédiée");

            var nextBackgroundCheck = DateTime.UtcNow;
            while (!cancellationToken.IsCancellationRequested && SteamProcessService.IsSteamRunning())
            {
                if (DateTime.UtcNow >= nextBackgroundCheck)
                {
                    _background.EnsureAll();
                    nextBackgroundCheck = DateTime.UtcNow.AddSeconds(10);
                }

                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
            }

            if (cancellationToken.IsCancellationRequested || _stopRequested)
            {
                return;
            }

            Publish(SteamSessionState.Restarting, "Steam s'est fermé, relance dans 2 secondes...");
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private static async Task<bool> WaitUntilRunningAsync(CancellationToken cancellationToken)
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < deadline && !cancellationToken.IsCancellationRequested)
        {
            if (SteamProcessService.IsSteamRunning())
            {
                return true;
            }

            try
            {
                await Task.Delay(250, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return false;
            }
        }

        return SteamProcessService.IsSteamRunning();
    }

    private void Publish(SteamSessionState state, string message)
    {
        State = state;
        StateChanged?.Invoke(this, new SteamSessionStateChangedEventArgs(state, message));
    }

    public ValueTask DisposeAsync()
    {
        lock (_sync)
        {
            if (_disposed)
            {
                return ValueTask.CompletedTask;
            }

            _disposed = true;
            _sessionCancellation?.Cancel();
            _sessionCancellation?.Dispose();
            _sessionCancellation = null;
        }

        return ValueTask.CompletedTask;
    }
}
