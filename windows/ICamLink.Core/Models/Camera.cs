namespace ICamLink.Core.Models;

/// <summary>Tapo exposes the HD feed on /stream1 and a low-resolution feed on /stream2.</summary>
public enum StreamQuality
{
    Main,
    Sub,
}

public enum ViewMode
{
    Focus,
    Grid,
}

public sealed record Camera(
    string Id,
    string Name,
    string Host,
    int Port,
    string Username,
    string Password)
{
    public static Camera Create(string name, string host, int port, string username, string password) =>
        new(Guid.NewGuid().ToString(), name, host, port, username, password);

    /// <summary>Credentials are passed to LibVLC as options, never embedded in the URL (special characters).</summary>
    public string RtspUrl(StreamQuality quality) =>
        $"rtsp://{Host}:{Port}/{(quality == StreamQuality.Main ? "stream1" : "stream2")}";
}
