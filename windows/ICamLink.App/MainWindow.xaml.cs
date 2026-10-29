using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using ICamLink.App.Interop;
using ICamLink.App.Views;

namespace ICamLink.App;

public partial class MainWindow : Window
{
    private readonly AppState _state = new();
    private readonly ViewerView _viewer;
    private readonly SettingsView _settings;
    private MiniWindow? _mini;
    private bool _fullscreen;
    private WindowState _stateBeforeFullscreen;

    public MainWindow()
    {
        InitializeComponent();
        _viewer = new ViewerView(_state);
        _settings = new SettingsView(_state);

        var s = _state.Settings;
        Width = s.Width;
        Height = s.Height;
        if (!double.IsNaN(s.Left) && !double.IsNaN(s.Top) && IsOnScreen(s.Left, s.Top))
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = s.Left;
            Top = s.Top;
        }
        else
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
        if (s.Maximized) Loaded += (_, _) => WindowState = WindowState.Maximized;

        _state.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppState.Screen)) ShowScreen();
            else if (e.PropertyName == nameof(AppState.Volume)) _mini?.SetVolume(_state.Volume);
        };
        ShowScreen();
    }

    private static bool IsOnScreen(double left, double top) =>
        left < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 50 &&
        top < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 50 &&
        left > SystemParameters.VirtualScreenLeft - 200 && top > SystemParameters.VirtualScreenTop - 50;

    private void OnSourceInitialized(object? sender, EventArgs e) =>
        DwmApi.SetImmersiveDarkMode(new WindowInteropHelper(this).Handle, true);

    /// <summary>
    /// Swapping the content removes the old screen from the visual tree, which unloads its camera
    /// views and releases every stream. A minimized window shows nothing, so it releases them too.
    /// </summary>
    private void ShowScreen()
    {
        if (WindowState == WindowState.Minimized)
        {
            Host.Content = null;
            return;
        }
        Host.Content = _state.Screen == AppScreen.Viewer ? _viewer : _settings;
    }

    private void OnStateChanged(object? sender, EventArgs e)
    {
        ShowScreen();
        UpdateMini();
    }

    /// <summary>
    /// Picture-in-picture: while the window is minimized a small always-on-top window keeps the last
    /// selected camera visible over other applications; restoring the main window closes it.
    /// </summary>
    private void UpdateMini()
    {
        if (WindowState != WindowState.Minimized)
        {
            _mini?.Close();
            return;
        }
        if (_mini != null || _state.SelectedCamera is not { } camera) return;

        var mini = new MiniWindow(_state, camera);
        mini.ExpandRequested += () =>
        {
            WindowState = WindowState.Normal;
            Activate();
        };
        mini.Closed += (_, _) => { if (_mini == mini) _mini = null; };
        _mini = mini;
        mini.Show();
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.F11)
        {
            ToggleFullscreen();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            if (_state.Screen == AppScreen.Settings) _settings.HandleEscape();
            else if (_fullscreen) ToggleFullscreen();
            e.Handled = true;
        }
    }

    private void ToggleFullscreen()
    {
        if (!_fullscreen)
        {
            _stateBeforeFullscreen = WindowState;
            WindowStyle = WindowStyle.None;
            WindowState = WindowState.Normal; // re-apply so the maximized bounds cover the taskbar
            WindowState = WindowState.Maximized;
            _fullscreen = true;
        }
        else
        {
            WindowStyle = WindowStyle.SingleBorderWindow;
            WindowState = _stateBeforeFullscreen;
            _fullscreen = false;
        }
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        _mini?.Close();
        if (_fullscreen) return; // fullscreen bounds shouldn't become the remembered window size
        var bounds = WindowState == WindowState.Normal ? new Rect(Left, Top, Width, Height) : RestoreBounds;
        _state.SaveWindow(bounds.Left, bounds.Top, bounds.Width, bounds.Height, WindowState == WindowState.Maximized);
    }
}
