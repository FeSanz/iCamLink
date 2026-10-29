using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using ICamLink.Core.Models;
using ICamLink.Core.Net;
using ICamLink.Core.Storage;

namespace ICamLink.App;

public enum AppScreen { Viewer, Settings }

/// <summary>Single source of truth shared by the viewer and settings screens.</summary>
public sealed class AppState : INotifyPropertyChanged
{
    private readonly CameraStore _store = new();
    private readonly OnvifDiscovery _discovery = new();
    private AppSettings _settings;
    private string? _selectedId;
    private ViewMode _mode;
    private int _volume;
    private int _volumeBeforeMute;
    private AppScreen _screen = AppScreen.Viewer;

    public AppState()
    {
        _settings = _store.LoadSettings();
        _selectedId = _settings.SelectedId;
        _mode = _settings.Mode;
        _volume = Math.Clamp(_settings.Volume, 0, 100);
        _volumeBeforeMute = _volume > 0 ? _volume : 60;
        Cameras = new ObservableCollection<Camera>(_store.LoadCameras());
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public ObservableCollection<Camera> Cameras { get; }
    public AppSettings Settings => _settings;

    /// <summary>Falls back to the first camera when nothing (valid) is selected.</summary>
    public Camera? SelectedCamera => Cameras.FirstOrDefault(c => c.Id == _selectedId) ?? Cameras.FirstOrDefault();

    public ViewMode Mode => _mode;
    public int Volume => _volume;

    public AppScreen Screen
    {
        get => _screen;
        private set { _screen = value; Raise(); }
    }

    public void Select(string id)
    {
        _selectedId = id;
        Persist();
        Raise(nameof(SelectedCamera));
    }

    public void FocusOn(string id)
    {
        _selectedId = id;
        SetMode(ViewMode.Focus);
        Raise(nameof(SelectedCamera));
    }

    public void ToggleMode() => SetMode(_mode == ViewMode.Focus ? ViewMode.Grid : ViewMode.Focus);

    private void SetMode(ViewMode mode)
    {
        _mode = mode;
        Persist();
        Raise(nameof(Mode));
    }

    public void SetVolume(int value)
    {
        _volume = Math.Clamp(value, 0, 100);
        if (_volume > 0) _volumeBeforeMute = _volume;
        Persist();
        Raise(nameof(Volume));
    }

    public void ToggleMute() => SetVolume(_volume == 0 ? _volumeBeforeMute : 0);

    public void OpenSettings() => Screen = AppScreen.Settings;

    public void CloseSettings()
    {
        StopScan();
        Screen = AppScreen.Viewer;
    }

    // --- mini player (floating thumbnail of the last selected camera, shown over the grid) ----------

    public double MiniWidth => _settings.MiniWidth;
    public double MiniX => _settings.MiniX;
    public double MiniY => _settings.MiniY;

    public void SetMiniLayout(double x, double y, double width)
    {
        _settings = _settings with { MiniX = x, MiniY = y, MiniWidth = width };
        _store.SaveSettings(_settings);
    }

    public void SaveWindow(double left, double top, double width, double height, bool maximized)
    {
        _settings = _settings with { Left = left, Top = top, Width = width, Height = height, Maximized = maximized };
        _store.SaveSettings(_settings);
    }

    private void Persist()
    {
        _settings = _settings with { SelectedId = _selectedId, Mode = _mode, Volume = _volume };
        _store.SaveSettings(_settings);
    }

    // --- cameras ---------------------------------------------------------------------------------

    public void Upsert(Camera camera)
    {
        var index = Cameras.ToList().FindIndex(c => c.Id == camera.Id);
        if (index >= 0) Cameras[index] = camera;
        else Cameras.Add(camera);
        _store.SaveCameras(Cameras);
        Raise(nameof(SelectedCamera));
    }

    public void Delete(string id)
    {
        var camera = Cameras.FirstOrDefault(c => c.Id == id);
        if (camera == null) return;
        Cameras.Remove(camera);
        _store.SaveCameras(Cameras);
        Raise(nameof(SelectedCamera));
    }

    public void Move(int from, int to)
    {
        if (from == to || from < 0 || to < 0 || from >= Cameras.Count || to >= Cameras.Count) return;
        Cameras.Move(from, to);
        _store.SaveCameras(Cameras);
    }

    public bool IsRegistered(string host) => Cameras.Any(c => c.Host == host);

    public void AddDiscovered(IEnumerable<DiscoveredCamera> selected, string username, string password)
    {
        foreach (var found in selected.Where(f => !IsRegistered(f.Host)))
            Cameras.Add(Camera.Create(found.Name ?? $"Cámara {Cameras.Count + 1}", found.Host, 554, username, password));
        _store.SaveCameras(Cameras);
        Raise(nameof(SelectedCamera));
    }

    // --- network scan ----------------------------------------------------------------------------

    private CancellationTokenSource? _scanCts;
    private bool _scanning;
    private double _scanProgress;
    private string? _scanError;
    private IReadOnlyList<DiscoveredCamera> _found = Array.Empty<DiscoveredCamera>();

    public bool Scanning { get => _scanning; private set { _scanning = value; Raise(); } }
    public double ScanProgress { get => _scanProgress; private set { _scanProgress = value; Raise(); } }
    public string? ScanError { get => _scanError; private set { _scanError = value; Raise(); } }
    public IReadOnlyList<DiscoveredCamera> Found { get => _found; private set { _found = value; Raise(); } }

    public async void StartScan()
    {
        _scanCts?.Cancel();
        var cts = _scanCts = new CancellationTokenSource();
        Found = Array.Empty<DiscoveredCamera>();
        ScanError = null;
        ScanProgress = 0;
        Scanning = true;
        var ui = Application.Current.Dispatcher;
        try
        {
            await Task.Run(() => _discovery.ScanAsync(
                (list, progress) => ui.BeginInvoke(() =>
                {
                    if (cts.IsCancellationRequested) return;
                    Found = list;
                    ScanProgress = progress;
                }), cts.Token));
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            ScanError = ex.Message;
        }
        finally
        {
            if (_scanCts == cts) Scanning = false;
        }
    }

    public void StopScan() => _scanCts?.Cancel();
}
