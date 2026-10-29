using System.Collections.Specialized;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ICamLink.App.Controls;
using ICamLink.Core.Models;

namespace ICamLink.App.Views;

public sealed class ThumbItem : INotifyPropertyChanged
{
    private bool _isMain;

    public ThumbItem(Camera camera, bool isMain)
    {
        Camera = camera;
        _isMain = isMain;
    }

    public Camera Camera { get; }

    public bool IsMain
    {
        get => _isMain;
        set
        {
            if (_isMain == value) return;
            _isMain = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsMain)));
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}

public partial class ViewerView : UserControl
{
    private readonly AppState _state;
    private readonly List<ThumbItem> _thumbs = new();
    private bool _syncingVolume;
    private (int Cols, int Rows, int Count) _gridShape;

    public ViewerView(AppState state)
    {
        _state = state;
        InitializeComponent();
        state.PropertyChanged += OnStateChanged;
        state.Cameras.CollectionChanged += (_, _) => Refresh();
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppState.Mode) or nameof(AppState.SelectedCamera)) Refresh();
        else if (e.PropertyName == nameof(AppState.Volume)) SyncVolume();
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => Refresh();

    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_state.Mode == ViewMode.Grid) BuildGrid(force: false);
    }

    private void Refresh()
    {
        var cameras = _state.Cameras;
        var selected = _state.SelectedCamera;
        var focus = _state.Mode == ViewMode.Focus && cameras.Count > 0;
        var grid = _state.Mode == ViewMode.Grid && cameras.Count > 0;

        EmptyState.Visibility = cameras.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        FocusRoot.Visibility = focus ? Visibility.Visible : Visibility.Collapsed;
        GridRoot.Visibility = grid ? Visibility.Visible : Visibility.Collapsed;
        ModeButton.Content = _state.Mode == ViewMode.Focus ? "" : "";
        ModeButton.ToolTip = _state.Mode == ViewMode.Focus ? "Vista en cuadrícula" : "Vista principal";
        ModeButton.IsEnabled = cameras.Count > 0;

        if (focus) SyncFocus(selected!);
        else
        {
            // Leaving focus mode releases every stream it held (sidebar + main) before the grid connects.
            _thumbs.Clear();
            Thumbs.ItemsSource = null;
            MainHost.Content = null;
        }

        if (grid) BuildGrid(force: true);
        else
        {
            GridRoot.Children.Clear();
            GridRoot.RowDefinitions.Clear();
            GridRoot.ColumnDefinitions.Clear();
            _gridShape = default;
        }
        SyncVolume();
    }

    // --- Mode 1 ------------------------------------------------------------------------------------

    private void SyncFocus(Camera selected)
    {
        var cameras = _state.Cameras;
        var same = _thumbs.Count == cameras.Count && _thumbs.Zip(cameras).All(p => ReferenceEquals(p.First.Camera, p.Second));
        if (!same)
        {
            _thumbs.Clear();
            _thumbs.AddRange(cameras.Select(c => new ThumbItem(c, c.Id == selected.Id)));
            Thumbs.ItemsSource = null;
            Thumbs.ItemsSource = _thumbs;
        }
        else
        {
            foreach (var t in _thumbs) t.IsMain = t.Camera.Id == selected.Id;
        }

        if (MainHost.Content is not CameraView view || view.Camera != selected)
        {
            MainHost.Content = new CameraView { Camera = selected, Quality = StreamQuality.Main, Volume = _state.Volume };
        }
        MainLabelText.Text = selected.Name;
    }

    private void OnThumbClick(object sender, MouseButtonEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is ThumbItem item) _state.Select(item.Camera.Id);
    }

    private void SyncVolume()
    {
        _syncingVolume = true;
        VolumeSlider.Value = _state.Volume;
        MuteButton.Content = _state.Volume == 0 ? "" : "";
        _syncingVolume = false;
        if (MainHost.Content is CameraView view) view.Volume = _state.Volume;
    }

    private void OnVolumeChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!_syncingVolume) _state.SetVolume((int)Math.Round(e.NewValue));
    }

    private void OnMuteClick(object sender, RoutedEventArgs e) => _state.ToggleMute();

    // --- Mode 2 ------------------------------------------------------------------------------------

    private void BuildGrid(bool force)
    {
        var cameras = _state.Cameras;
        // GridRoot may not have been measured yet (it was collapsed); the view's own size minus its margin is the same.
        var width = ActualWidth - 4;
        var height = ActualHeight - 4;
        if (cameras.Count == 0 || width < 1 || height < 1) return;

        var (cols, rows) = BestGrid(cameras.Count, width, height);
        if (!force && _gridShape == (cols, rows, cameras.Count)) return;
        _gridShape = (cols, rows, cameras.Count);

        GridRoot.Children.Clear();
        GridRoot.RowDefinitions.Clear();
        GridRoot.ColumnDefinitions.Clear();
        for (var c = 0; c < cols; c++) GridRoot.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var r = 0; r < rows; r++) GridRoot.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        for (var i = 0; i < cameras.Count; i++)
        {
            var camera = cameras[i];
            var cell = new Grid { Margin = new Thickness(1), Background = Brushes.Transparent, Cursor = Cursors.Hand };
            UIElement content = new CameraView { Camera = camera, Quality = StreamQuality.Sub };
            cell.Children.Add(new RoundedClip { Radius = 6, Child = content });
            cell.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(6),
                BorderThickness = new Thickness(1),
                BorderBrush = (Brush)FindResource("BorderBrush"),
                IsHitTestVisible = false,
            });
            cell.Children.Add(new Border
            {
                Background = (Brush)FindResource("ScrimBrush"),
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(8, 2, 8, 2),
                Margin = new Thickness(6),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Bottom,
                IsHitTestVisible = false,
                Child = new TextBlock { Text = camera.Name, FontSize = 11, Foreground = Brushes.White },
            });
            var id = camera.Id;
            cell.MouseLeftButtonUp += (_, _) => _state.FocusOn(id);
            Grid.SetColumn(cell, i % cols);
            Grid.SetRow(cell, i / cols);
            GridRoot.Children.Add(cell);
        }
    }

    /// <summary>Picks the cols×rows layout whose 16:9 cells come out largest (3→2x2, 4→2x2, 6→3x2, ...).</summary>
    private static (int Cols, int Rows) BestGrid(int count, double width, double height)
    {
        var best = (Cols: 1, Rows: count);
        var bestSize = 0.0;
        for (var cols = 1; cols <= count; cols++)
        {
            var rows = (int)Math.Ceiling(count / (double)cols);
            var size = Math.Min(width / cols, height / rows * 16.0 / 9.0);
            if (size > bestSize * 0.999)
            {
                bestSize = size;
                best = (cols, rows);
            }
        }
        return best;
    }

    private void OnToggleMode(object sender, RoutedEventArgs e) => _state.ToggleMode();

    private void OnOpenSettings(object sender, RoutedEventArgs e) => _state.OpenSettings();
}
