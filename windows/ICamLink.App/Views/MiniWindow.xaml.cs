using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using ICamLink.Core.Models;

namespace ICamLink.App.Views;

/// <summary>
/// Picture-in-picture window: while the main window is minimized this small always-on-top window keeps
/// the last selected camera (HD stream, with audio) on screen over other applications. It is a
/// separate top-level window with no owner, so it stays visible when the main window is minimized.
/// Dragged from its body, resized from its edges at a fixed 16:9.
/// </summary>
public partial class MiniWindow : Window
{
    private const double Aspect = 16.0 / 9.0;
    private const int WM_SIZING = 0x0214;
    private const int WMSZ_LEFT = 1, WMSZ_RIGHT = 2, WMSZ_TOP = 3, WMSZ_TOPLEFT = 4,
                      WMSZ_TOPRIGHT = 5, WMSZ_BOTTOM = 6, WMSZ_BOTTOMLEFT = 7, WMSZ_BOTTOMRIGHT = 8;

    private readonly AppState _state;
    private bool _syncingVolume;

    public MiniWindow(AppState state, Camera camera)
    {
        _state = state;
        InitializeComponent();
        Video.Camera = camera;
        NameText.Text = camera.Name;
        SetVolume(state.Volume);
        Place();
    }

    /// <summary>Raised when the user wants the full window back.</summary>
    public event Action? ExpandRequested;

    public void SetVolume(int percent)
    {
        _syncingVolume = true;
        VolumeSlider.Value = percent;
        _syncingVolume = false;
        MuteButton.Content = percent == 0 ? "" : "";
        Video.Volume = percent;
    }

    /// <summary>Restores the last size/position, or sits in the bottom-right of the work area.</summary>
    private void Place()
    {
        var area = SystemParameters.WorkArea;
        var width = Math.Clamp(_state.MiniWidth, MinWidth, Math.Max(MinWidth, area.Width - 32));
        var height = width / Aspect;
        Width = width;
        Height = height;
        var fits = !double.IsNaN(_state.MiniX) && !double.IsNaN(_state.MiniY)
                   && _state.MiniX > SystemParameters.VirtualScreenLeft - 50
                   && _state.MiniY > SystemParameters.VirtualScreenTop - 50
                   && _state.MiniX < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 80
                   && _state.MiniY < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 80;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = fits ? _state.MiniX : area.Right - width - 16;
        Top = fits ? _state.MiniY : area.Bottom - height - 16;
    }

    private void OnSourceInitialized(object? sender, EventArgs e) =>
        HwndSource.FromHwnd(new WindowInteropHelper(this).Handle)?.AddHook(WndProc);

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e) =>
        _state.SetMiniLayout(Left, Top, Width);

    private void OnDrag(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }

    private void OnVolumeSlider(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!_syncingVolume) _state.SetVolume((int)Math.Round(e.NewValue));
    }

    private void OnMute(object sender, RoutedEventArgs e) => _state.ToggleMute();
    private void OnExpand(object sender, RoutedEventArgs e) => ExpandRequested?.Invoke();
    private void OnClose(object sender, RoutedEventArgs e) => Close();

    // Keeps the window 16:9 while it is being resized (the rect is in physical pixels).
    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_SIZING) return IntPtr.Zero;

        var r = Marshal.PtrToStructure<RECT>(lParam);
        var edge = wParam.ToInt32();
        var width = r.Right - r.Left;
        var height = r.Bottom - r.Top;

        if (edge is WMSZ_TOP or WMSZ_BOTTOM) width = (int)Math.Round(height * Aspect);
        else height = (int)Math.Round(width / Aspect);

        if (edge is WMSZ_LEFT or WMSZ_TOPLEFT or WMSZ_BOTTOMLEFT) r.Left = r.Right - width; else r.Right = r.Left + width;
        if (edge is WMSZ_TOP or WMSZ_TOPLEFT or WMSZ_TOPRIGHT) r.Top = r.Bottom - height; else r.Bottom = r.Top + height;

        Marshal.StructureToPtr(r, lParam, false);
        handled = true;
        return (IntPtr)1;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left, Top, Right, Bottom;
    }
}
