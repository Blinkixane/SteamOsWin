using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace SteamOsWin.Services;

public sealed class GlobalHotKey : IDisposable
{
    private const int WmHotKey = 0x0312;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const int VirtualKeyW = 0x57;

    private readonly HwndSource _source;
    private readonly int _id;
    private bool _registered;

    public GlobalHotKey(IntPtr windowHandle)
    {
        _source = HwndSource.FromHwnd(windowHandle)
            ?? throw new InvalidOperationException("Impossible d'obtenir la source de fenêtre.");
        _id = GetHashCode();
        _source.AddHook(WndProc);
        _registered = RegisterHotKey(windowHandle, _id, ModControl | ModAlt, VirtualKeyW);
        RegistrationError = _registered ? 0 : Marshal.GetLastWin32Error();
    }

    public event EventHandler? Pressed;

    public bool IsRegistered => _registered;

    public int RegistrationError { get; }

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmHotKey && wParam.ToInt32() == _id)
        {
            Pressed?.Invoke(this, EventArgs.Empty);
            handled = true;
        }

        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_registered)
        {
            UnregisterHotKey(_source.Handle, _id);
            _registered = false;
        }

        _source.RemoveHook(WndProc);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, int vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
