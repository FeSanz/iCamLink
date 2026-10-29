using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using ICamLink.Core.Models;
using LibVLCSharp.Shared;
using MediaPlayer = LibVLCSharp.Shared.MediaPlayer;

namespace ICamLink.App.Streaming;

public enum StreamStatus { Connecting, Live, Reconnecting }

/// <summary>
/// One RTSP connection (one LibVLC player) to one camera at one quality. Decoded frames are pulled
/// through LibVLC's video callbacks into a <see cref="WriteableBitmap"/>, so the picture is a plain
/// WPF image (no child HWND) and can be overlaid, clipped and dragged over like any other element.
/// </summary>
internal sealed class RtspSession
{
    private enum Signal { Playing, Alive, Failed }

    private const int MaxFrameWidth = 1920;
    private const int StartDebounceMs = 150;
    private const int ConnectTimeoutMs = 10_000;
    private const int StallTimeoutMs = 6_000;
    private const int RetryStepMs = 1000;
    private const int RetryMaxMs = 8000;

    private readonly Camera _camera;
    private readonly StreamQuality _quality;
    private readonly bool _audio;
    private readonly Dispatcher _ui = Application.Current.Dispatcher;
    private readonly Channel<Signal> _signals = Channel.CreateUnbounded<Signal>();
    private readonly CancellationTokenSource _cts = new();
    private readonly object _frameLock = new();

    private MediaPlayer? _player;
    private bool _released;
    private int _volume;
    private bool _volumeApplied;

    // Video callback state (delegates are fields so the GC can't collect them while native code holds them).
    private readonly MediaPlayer.LibVLCVideoFormatCb _formatCb;
    private readonly MediaPlayer.LibVLCVideoCleanupCb _cleanupCb;
    private readonly MediaPlayer.LibVLCVideoLockCb _lockCb;
    private readonly MediaPlayer.LibVLCVideoUnlockCb _unlockCb;
    private readonly MediaPlayer.LibVLCVideoDisplayCb _displayCb;
    private IntPtr _buffer;
    private int _width, _height, _pitch;
    private WriteableBitmap? _bitmap;
    private bool _renderPending;

    public StreamStatus Status { get; private set; } = StreamStatus.Connecting;
    public int Attempt { get; private set; }

    /// <summary>Raised on the UI thread when the bitmap instance is (re)created.</summary>
    public event Action<ImageSource>? FrameSourceChanged;
    public event Action? StatusChanged;

    public RtspSession(Camera camera, StreamQuality quality, bool audio)
    {
        _camera = camera;
        _quality = quality;
        _audio = audio;
        _formatCb = OnFormat;
        _cleanupCb = (ref IntPtr _) => { };
        _lockCb = OnLock;
        _unlockCb = (_, _, _) => Monitor.Exit(_frameLock);
        _displayCb = (_, _) => OnDisplay();
    }

    public void Start()
    {
        if (_released || _player != null) return;
        var p = new MediaPlayer(StreamManager.Vlc);
        p.SetVideoFormatCallbacks(_formatCb, _cleanupCb);
        p.SetVideoCallbacks(_lockCb, _unlockCb, _displayCb);
        p.Playing += (_, _) => _signals.Writer.TryWrite(Signal.Playing);
        p.EncounteredError += (_, _) => _signals.Writer.TryWrite(Signal.Failed);
        p.EndReached += (_, _) => _signals.Writer.TryWrite(Signal.Failed);
        p.Buffering += (_, _) => _signals.Writer.TryWrite(Signal.Alive);
        p.TimeChanged += (_, _) => _signals.Writer.TryWrite(Signal.Alive);
        p.Opening += (_, _) => _signals.Writer.TryWrite(Signal.Alive);
        _player = p;
        _ = RunAsync(p, _cts.Token);
    }

    public void SetVolume(int percent)
    {
        _volume = percent;
        _volumeApplied = false;
        if (_player != null) TryApplyVolume(_player);
    }

    public void Release()
    {
        if (_released) return;
        _released = true;
        _cts.Cancel();
        var p = _player;
        _player = null;
        if (p == null) { FreeBuffer(); return; }
        // Stop() may block on the RTSP TEARDOWN, so it runs off the UI thread, serialized per camera.
        StreamManager.Teardown(_camera.Id, () =>
        {
            p.Stop();
            p.Dispose();
            FreeBuffer();
        });
    }

    private async Task RunAsync(MediaPlayer p, CancellationToken ct)
    {
        try
        {
            await Task.Delay(StartDebounceMs, ct); // rapid selection changes never reach the camera
            await StreamManager.AwaitFree(_camera.Id);
            var attempt = 0;
            while (!ct.IsCancellationRequested)
            {
                SetStatus(attempt == 0 ? StreamStatus.Connecting : StreamStatus.Reconnecting, attempt);
                while (_signals.Reader.TryRead(out _)) { }
                _volumeApplied = false;
                Play(p);

                var playing = false;
                while (true)
                {
                    var signal = await ReadAsync(playing ? StallTimeoutMs : ConnectTimeoutMs, ct);
                    if (signal is null or Signal.Failed) break;
                    if (signal == Signal.Playing)
                    {
                        if (!playing)
                        {
                            playing = true;
                            attempt = 0;
                        }
                        SetStatus(StreamStatus.Live, 0);
                    }
                    if (playing && !_volumeApplied) TryApplyVolume(p);
                }

                await Task.Run(() => p.Stop(), CancellationToken.None);
                attempt++;
                SetStatus(StreamStatus.Reconnecting, attempt);
                await Task.Delay(Math.Min(RetryStepMs * attempt, RetryMaxMs), ct);
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>
    /// LibVLC creates the audio output after the Playing event, and a volume set before that is lost
    /// (reads back as -1), which left a newly selected camera silent until the slider moved. So it
    /// is re-applied on every progress signal until the read-back confirms it stuck.
    /// </summary>
    private void TryApplyVolume(MediaPlayer p)
    {
        if (!_audio) return;
        try
        {
            p.Volume = _volume;
            _volumeApplied = p.Volume == _volume;
        }
        catch { /* player may be mid-teardown */ }
    }

    private async Task<Signal?> ReadAsync(int timeoutMs, CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeoutMs);
        try { return await _signals.Reader.ReadAsync(cts.Token); }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return null; }
    }

    private void Play(MediaPlayer p)
    {
        using var media = new Media(StreamManager.Vlc, new Uri(_camera.RtspUrl(_quality)));
        media.AddOption(":network-caching=300");
        media.AddOption(":live-caching=300");
        media.AddOption(":rtsp-tcp");
        media.AddOption(":clock-jitter=0");
        media.AddOption(":clock-synchro=0");
        media.AddOption($":rtsp-user={_camera.Username}");
        media.AddOption($":rtsp-pwd={_camera.Password}");
        if (!_audio) media.AddOption(":no-audio");
        p.Media = media; // the player keeps its own reference; ours is released by the using
        p.Play();
    }

    private void SetStatus(StreamStatus status, int attempt)
    {
        _ui.BeginInvoke(() =>
        {
            if (_released) return;
            Status = status;
            Attempt = attempt;
            StatusChanged?.Invoke();
        });
    }

    // --- video callbacks (VLC threads) -----------------------------------------------------------

    private uint OnFormat(ref IntPtr opaque, IntPtr chroma, ref uint width, ref uint height, ref uint pitches, ref uint lines)
    {
        Marshal.Copy(Encoding.ASCII.GetBytes("RV32"), 0, chroma, 4); // BGRA, matches Bgra32 below

        var w = (int)width;
        var h = (int)height;
        if (w > MaxFrameWidth)
        {
            h = (int)Math.Round(h * (double)MaxFrameWidth / w);
            w = MaxFrameWidth;
        }
        w &= ~1;
        h &= ~1;
        width = (uint)w;
        height = (uint)h;
        pitches = (uint)(w * 4);
        lines = (uint)h;

        lock (_frameLock)
        {
            FreeBuffer();
            _width = w;
            _height = h;
            _pitch = w * 4;
            _buffer = Marshal.AllocHGlobal(_pitch * h);
        }
        _ui.BeginInvoke(() =>
        {
            if (_released) return;
            _bitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgra32, null);
            FrameSourceChanged?.Invoke(_bitmap);
        });
        return 1;
    }

    private IntPtr OnLock(IntPtr opaque, IntPtr planes)
    {
        Monitor.Enter(_frameLock);
        Marshal.WriteIntPtr(planes, _buffer);
        return IntPtr.Zero;
    }

    private void OnDisplay()
    {
        lock (_frameLock)
        {
            if (_renderPending) return;
            _renderPending = true;
        }
        _ui.BeginInvoke(DispatcherPriority.Render, Render);
    }

    private void Render()
    {
        var bmp = _bitmap;
        lock (_frameLock)
        {
            _renderPending = false;
            if (_released || bmp == null || _buffer == IntPtr.Zero || bmp.PixelWidth != _width || bmp.PixelHeight != _height) return;
            bmp.Lock();
            unsafe
            {
                Buffer.MemoryCopy((void*)_buffer, (void*)bmp.BackBuffer, (long)bmp.BackBufferStride * _height, (long)_pitch * _height);
            }
            bmp.AddDirtyRect(new Int32Rect(0, 0, _width, _height));
            bmp.Unlock();
        }
    }

    private void FreeBuffer()
    {
        lock (_frameLock)
        {
            if (_buffer == IntPtr.Zero) return;
            Marshal.FreeHGlobal(_buffer);
            _buffer = IntPtr.Zero;
        }
    }
}
