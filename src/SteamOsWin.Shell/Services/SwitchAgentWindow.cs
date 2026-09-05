using System.Windows;
using System.Windows.Interop;
using WpfMessageBox = System.Windows.MessageBox;

namespace SteamOsWin.Services;

/// <summary>
/// Hidden per-user agent used by the normal Explorer session. The gaming
/// shell has its own hotkey, while this agent makes the same shortcut work in
/// both directions without keeping Explorer out of the normal session.
/// </summary>
public sealed class SwitchAgentWindow : Window
{
    private GlobalHotKey? _hotKey;
    private bool _switchInProgress;

    public SwitchAgentWindow()
    {
        Width = 1;
        Height = 1;
        ShowInTaskbar = false;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        Visibility = Visibility.Hidden;
        SourceInitialized += OnSourceInitialized;
        Closed += OnClosed;
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hotKey = new GlobalHotKey(new WindowInteropHelper(this).Handle);
        _hotKey.Pressed += OnHotKeyPressed;
    }

    private void OnHotKeyPressed(object? sender, EventArgs e)
    {
        if (_switchInProgress)
        {
            return;
        }

        _switchInProgress = true;
        try
        {
            var result = SessionSwitcher.Request();
            if (!result.Success)
            {
                WpfMessageBox.Show(result.Message, "SteamOS-Win", MessageBoxButton.OK, MessageBoxImage.Information);
                _switchInProgress = false;
            }
            else
            {
                _ = ReleaseSwitchGuardAfterDelayAsync();
            }
        }
        catch (Exception exception)
        {
            WpfMessageBox.Show(exception.Message, "SteamOS-Win", MessageBoxButton.OK, MessageBoxImage.Warning);
            _switchInProgress = false;
        }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _hotKey?.Dispose();
    }

    private async Task ReleaseSwitchGuardAfterDelayAsync()
    {
        await Task.Delay(TimeSpan.FromSeconds(5));
        _switchInProgress = false;
    }
}
