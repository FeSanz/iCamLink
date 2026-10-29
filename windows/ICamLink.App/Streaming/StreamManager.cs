using LibVLCSharp.Shared;

namespace ICamLink.App.Streaming;

/// <summary>
/// Tapo cameras only accept a handful of simultaneous RTSP clients, so a new session for a camera
/// must never start while the previous one for that same camera is still tearing down.
/// Teardowns are serialized per camera here and new sessions wait for them (<see cref="AwaitFree"/>).
/// </summary>
internal static class StreamManager
{
    private static readonly Dictionary<string, Task> Teardowns = new(); // UI thread only
    private static LibVLC? _vlc;

    public static LibVLC Vlc
    {
        get
        {
            if (_vlc != null) return _vlc;
            LibVLCSharp.Shared.Core.Initialize();
            _vlc = new LibVLC("--no-stats", "--drop-late-frames", "--skip-frames", "--no-osd");
            return _vlc;
        }
    }

    public static Task AwaitFree(string cameraId) =>
        Teardowns.TryGetValue(cameraId, out var t) ? t : Task.CompletedTask;

    public static void Teardown(string cameraId, Action block)
    {
        var previous = AwaitFree(cameraId);
        Teardowns[cameraId] = Task.Run(async () =>
        {
            try { await previous; } catch { /* previous teardown failing must not block this one */ }
            try { block(); } catch { /* native stop/dispose errors are not actionable */ }
            await Task.Delay(250); // let the camera notice the TEARDOWN and free the slot
        });
    }
}
