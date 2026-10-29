using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using ICamLink.App.Streaming;
using ICamLink.Core.Models;

namespace ICamLink.App.Controls;

/// <summary>
/// Plays one camera at one quality. Leaving the visual tree (deselected, scrolled out, mode switch,
/// window minimized) stops and releases the player so its RTSP slot is freed.
/// <see cref="Volume"/> == null means a muted preview (audio isn't even requested).
/// </summary>
public partial class CameraView : UserControl
{
    public static readonly DependencyProperty CameraProperty = DependencyProperty.Register(
        nameof(Camera), typeof(Camera), typeof(CameraView), new PropertyMetadata(null, OnSourceChanged));

    public static readonly DependencyProperty QualityProperty = DependencyProperty.Register(
        nameof(Quality), typeof(StreamQuality), typeof(CameraView), new PropertyMetadata(StreamQuality.Sub, OnSourceChanged));

    public static readonly DependencyProperty VolumeProperty = DependencyProperty.Register(
        nameof(Volume), typeof(int?), typeof(CameraView), new PropertyMetadata(null, OnVolumeChanged));

    private RtspSession? _session;

    public CameraView()
    {
        InitializeComponent();
        Spinner.Foreground = (Brush)FindResource("AccentSoftBrush");
    }

    public Camera? Camera { get => (Camera?)GetValue(CameraProperty); set => SetValue(CameraProperty, value); }
    public StreamQuality Quality { get => (StreamQuality)GetValue(QualityProperty); set => SetValue(QualityProperty, value); }
    public int? Volume { get => (int?)GetValue(VolumeProperty); set => SetValue(VolumeProperty, value); }

    private static void OnSourceChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (CameraView)d;
        if (view.IsLoaded) view.Restart();
    }

    private static void OnVolumeChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (CameraView)d;
        if (view._session == null) return;
        if ((e.OldValue == null) != (e.NewValue == null)) view.Restart(); // audio on/off changes the media options
        else view._session.SetVolume((int?)e.NewValue ?? 0);
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => Restart();

    private void OnUnloaded(object sender, RoutedEventArgs e) => Stop();

    private void Restart()
    {
        Stop();
        if (Camera is not { } camera) return;

        var session = new RtspSession(camera, Quality, Volume != null);
        session.FrameSourceChanged += source => { if (_session == session) Frame.Source = source; };
        session.StatusChanged += () => { if (_session == session) UpdateStatus(session); };
        session.SetVolume(Volume ?? 0);
        _session = session;
        UpdateStatus(session);
        session.Start();
    }

    private void Stop()
    {
        var session = _session;
        _session = null;
        Frame.Source = null;
        StopSpinner();
        session?.Release();
    }

    private void UpdateStatus(RtspSession session)
    {
        if (session.Status == StreamStatus.Live)
        {
            StatusPill.Visibility = Visibility.Collapsed;
            StopSpinner();
            return;
        }
        var reconnecting = session.Status == StreamStatus.Reconnecting;
        StatusText.Text = reconnecting ? "Reconectando…" : "Conectando…";
        StatusText.Foreground = (Brush)FindResource(reconnecting ? "WarnBrush" : "AccentSoftBrush");
        StatusPill.Visibility = Visibility.Visible;
        StartSpinner();
    }

    private void StartSpinner()
    {
        var spin = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever };
        SpinnerRotation.BeginAnimation(RotateTransform.AngleProperty, spin);
    }

    private void StopSpinner() => SpinnerRotation.BeginAnimation(RotateTransform.AngleProperty, null);
}
