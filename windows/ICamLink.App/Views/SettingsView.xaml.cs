using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ICamLink.Core.Models;
using ICamLink.Core.Net;

namespace ICamLink.App.Views;

public sealed class FoundItem : INotifyPropertyChanged
{
    private bool _isChecked;

    public FoundItem(DiscoveredCamera camera, bool registered)
    {
        Camera = camera;
        Registered = registered;
    }

    public DiscoveredCamera Camera { get; }
    public bool Registered { get; }
    public bool CanSelect => !Registered;
    public string Title => Camera.Name ?? $"Cámara {Camera.Host[(Camera.Host.LastIndexOf('.') + 1)..]}";
    public string Badge => Registered ? "Ya agregada" : Camera.Onvif ? "ONVIF" : "RTSP";

    public Brush BadgeBrush => (Brush)Application.Current.FindResource(
        Camera.Onvif && !Registered ? "AccentBrush" : "MutedBrush");

    public bool IsChecked
    {
        get => _isChecked || Registered;
        set
        {
            if (Registered || _isChecked == value) return;
            _isChecked = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsChecked)));
            Changed?.Invoke();
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? Changed;
}

public partial class SettingsView : UserControl
{
    private enum Pane { None, Scan, Edit }

    private readonly AppState _state;
    private readonly List<FoundItem> _foundItems = new();
    private Camera? _editing;
    private Point _dragStart;
    private ListBoxItem? _dropHint;

    public SettingsView(AppState state)
    {
        _state = state;
        InitializeComponent();
        CameraList.ItemsSource = state.Cameras;
        state.Cameras.CollectionChanged += (_, _) => RefreshCameraTitle();
        state.PropertyChanged += OnStateChanged;
        Loaded += (_, _) =>
        {
            RefreshCameraTitle();
            ShowPane(Pane.None);
        };
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppState.Found) or nameof(AppState.Scanning) or nameof(AppState.ScanProgress) or nameof(AppState.ScanError))
            RefreshScan();
    }

    private void RefreshCameraTitle() => CamerasTitle.Text = $"CÁMARAS ({_state.Cameras.Count})";

    private void ShowPane(Pane pane)
    {
        IdleHint.Visibility = pane == Pane.None ? Visibility.Visible : Visibility.Collapsed;
        ScanPane.Visibility = pane == Pane.Scan ? Visibility.Visible : Visibility.Collapsed;
        EditorPane.Visibility = pane == Pane.Edit ? Visibility.Visible : Visibility.Collapsed;
        if (pane != Pane.Scan) _state.StopScan();
    }

    private void OnBack(object sender, RoutedEventArgs e) => _state.CloseSettings();

    /// <summary>Esc steps back: closes an open pane first, then the settings screen.</summary>
    public void HandleEscape()
    {
        if (ScanPane.Visibility == Visibility.Visible || EditorPane.Visibility == Visibility.Visible) ShowPane(Pane.None);
        else _state.CloseSettings();
    }

    // --- camera list: edit / delete / drag-to-reorder --------------------------------------------

    private void OnEditCamera(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is Camera camera) OpenEditor(camera);
    }

    private void OnDeleteCamera(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not Camera camera) return;
        var answer = MessageBox.Show($"¿Eliminar \"{camera.Name}\" ({camera.Host})?", "Eliminar cámara",
            MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (answer != MessageBoxResult.Yes) return;
        _state.Delete(camera.Id);
        if (_editing?.Id == camera.Id) ShowPane(Pane.None);
    }

    private void OnListMouseDown(object sender, MouseButtonEventArgs e) => _dragStart = e.GetPosition(null);

    private void OnListMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed) return;
        var pos = e.GetPosition(null);
        if (Math.Abs(pos.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance &&
            Math.Abs(pos.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance) return;
        if (FindAncestor<Button>(e.OriginalSource as DependencyObject) != null) return;
        if (ItemsControl.ContainerFromElement(CameraList, (DependencyObject)e.OriginalSource) is not ListBoxItem item) return;
        if (item.DataContext is not Camera camera) return;

        DragDrop.DoDragDrop(item, new DataObject("icamlink/camera", camera.Id), DragDropEffects.Move);
        ClearDropHint();
    }

    private void OnListDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent("icamlink/camera") ? DragDropEffects.Move : DragDropEffects.None;
        e.Handled = true;
        var target = ItemsControl.ContainerFromElement(CameraList, e.OriginalSource as DependencyObject) as ListBoxItem;
        if (target == _dropHint) return;
        ClearDropHint();
        _dropHint = target;
        if (_dropHint != null) _dropHint.Background = (Brush)FindResource("SurfaceAltBrush");
    }

    private void OnListDragLeave(object sender, DragEventArgs e) => ClearDropHint();

    private void OnListDrop(object sender, DragEventArgs e)
    {
        ClearDropHint();
        if (e.Data.GetData("icamlink/camera") is not string id) return;
        var from = _state.Cameras.ToList().FindIndex(c => c.Id == id);
        var target = ItemsControl.ContainerFromElement(CameraList, e.OriginalSource as DependencyObject) as ListBoxItem;
        var to = target?.DataContext is Camera t ? _state.Cameras.IndexOf(t) : _state.Cameras.Count - 1;
        _state.Move(from, to);
        e.Handled = true;
    }

    private void ClearDropHint()
    {
        if (_dropHint != null) _dropHint.Background = Brushes.Transparent;
        _dropHint = null;
    }

    private static T? FindAncestor<T>(DependencyObject? d) where T : DependencyObject
    {
        while (d != null)
        {
            if (d is T t) return t;
            d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
        }
        return null;
    }

    // --- A. scan -----------------------------------------------------------------------------------

    private void OnScan(object sender, RoutedEventArgs e)
    {
        _foundItems.Clear();
        ScanTestResult.Text = "";
        ShowPane(Pane.Scan);
        _state.StartScan();
        RefreshScan();
    }

    private void OnScanToggle(object sender, RoutedEventArgs e)
    {
        if (_state.Scanning) _state.StopScan();
        else OnScan(sender, e);
    }

    private void RefreshScan()
    {
        // Keep the user's checkmarks while results stream in.
        var checkedHosts = _foundItems.Where(f => f.IsChecked && !f.Registered).Select(f => f.Camera.Host).ToHashSet();
        foreach (var f in _foundItems) f.Changed -= UpdateScanButtons;
        _foundItems.Clear();
        foreach (var cam in _state.Found)
        {
            var item = new FoundItem(cam, _state.IsRegistered(cam.Host)) { };
            item.IsChecked = checkedHosts.Contains(cam.Host);
            item.Changed += UpdateScanButtons;
            _foundItems.Add(item);
        }
        FoundList.ItemsSource = null;
        FoundList.ItemsSource = _foundItems;

        FoundTitle.Text = $"CÁMARAS ENCONTRADAS ({_foundItems.Count})";
        ScanToggle.Content = _state.Scanning ? "Detener" : "Volver a escanear";
        ScanBar.Visibility = _state.Scanning ? Visibility.Visible : Visibility.Hidden;
        ScanBar.Value = _state.ScanProgress;
        ScanErrorText.Text = _state.ScanError ?? "";
        NoneFound.Visibility = !_state.Scanning && _foundItems.Count == 0 && _state.ScanError == null
            ? Visibility.Visible : Visibility.Collapsed;
        UpdateScanButtons();
    }

    private IEnumerable<FoundItem> Chosen => _foundItems.Where(f => f.IsChecked && !f.Registered);

    private void UpdateScanButtons()
    {
        var chosen = Chosen.Count();
        var hasUser = !string.IsNullOrWhiteSpace(ScanUser.Text);
        ScanAdd.Content = $"Añadir ({chosen})";
        ScanAdd.IsEnabled = chosen > 0 && hasUser;
        ScanTest.IsEnabled = chosen > 0 && hasUser;
    }

    private void OnFoundRowClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && FindAncestor<CheckBox>(d) != null) return; // the checkbox toggles itself
        if (((FrameworkElement)sender).DataContext is FoundItem item) item.IsChecked = !item.IsChecked;
    }

    private void OnScanCredsChanged(object sender, RoutedEventArgs e)
    {
        ScanTestResult.Text = "";
        if (IsLoaded) UpdateScanButtons();
    }

    private async void OnScanTest(object sender, RoutedEventArgs e)
    {
        var first = Chosen.FirstOrDefault();
        if (first == null) return;
        ScanTest.IsEnabled = false;
        ScanTest.Content = "Probando…";
        ScanTestResult.Text = "";
        var result = await RtspProbe.ProbeAsync(first.Camera.Host, 554, ScanUser.Text.Trim(), ScanPass.Password);
        ShowResult(ScanTestResult, result);
        ScanTest.Content = "Probar";
        UpdateScanButtons();
    }

    private void OnScanAdd(object sender, RoutedEventArgs e)
    {
        _state.AddDiscovered(Chosen.Select(f => f.Camera).ToList(), ScanUser.Text.Trim(), ScanPass.Password);
        ShowPane(Pane.None);
    }

    private void ShowResult(TextBlock target, ProbeResult result)
    {
        target.Text = result.Message;
        target.Foreground = (Brush)FindResource(result.Ok ? "LiveBrush" : "DangerBrush");
    }

    // --- B. manual add / edit ----------------------------------------------------------------------

    private void OnAddManual(object sender, RoutedEventArgs e) => OpenEditor(null);

    private void OpenEditor(Camera? camera)
    {
        _editing = camera;
        EditorTitle.Text = camera == null ? "NUEVA CÁMARA" : "EDITAR CÁMARA";
        NameBox.Text = camera?.Name ?? "";
        HostBox.Text = camera?.Host ?? "";
        PortBox.Text = (camera?.Port ?? 554).ToString();
        UserBox.Text = camera?.Username ?? "";
        PassBox.Password = camera?.Password ?? "";
        EditorResult.Text = "";
        ShowPane(Pane.Edit);
        UpdateEditorButtons();
    }

    private bool TryPort(out int port) =>
        int.TryParse(PortBox.Text, out port) && port is >= 1 and <= 65535;

    private void UpdateEditorButtons()
    {
        if (EditorSave == null) return;
        var valid = !string.IsNullOrWhiteSpace(NameBox.Text) && !string.IsNullOrWhiteSpace(HostBox.Text)
                    && TryPort(out _) && !string.IsNullOrWhiteSpace(UserBox.Text);
        EditorSave.IsEnabled = valid;
        EditorTest.IsEnabled = valid;
    }

    private void OnEditorChanged(object sender, RoutedEventArgs e)
    {
        if (EditorResult != null) EditorResult.Text = "";
        UpdateEditorButtons();
    }

    private void OnPortInput(object sender, TextCompositionEventArgs e) => e.Handled = !e.Text.All(char.IsDigit);

    private async void OnEditorTest(object sender, RoutedEventArgs e)
    {
        if (!TryPort(out var port)) return;
        EditorTest.IsEnabled = false;
        EditorTest.Content = "Probando…";
        EditorResult.Text = "";
        var result = await RtspProbe.ProbeAsync(HostBox.Text.Trim(), port, UserBox.Text.Trim(), PassBox.Password);
        ShowResult(EditorResult, result);
        EditorTest.Content = "Probar conexión";
        UpdateEditorButtons();
    }

    private void OnEditorSave(object sender, RoutedEventArgs e)
    {
        if (!TryPort(out var port)) return;
        var camera = (_editing ?? Camera.Create("", "", port, "", "")) with
        {
            Name = NameBox.Text.Trim(),
            Host = HostBox.Text.Trim(),
            Port = port,
            Username = UserBox.Text.Trim(),
            Password = PassBox.Password,
        };
        _state.Upsert(camera);
        ShowPane(Pane.None);
    }

    private void OnEditorCancel(object sender, RoutedEventArgs e) => ShowPane(Pane.None);
}
