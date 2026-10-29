using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ICamLink.Core.Models;

namespace ICamLink.Core.Storage;

public sealed record AppSettings(
    string? SelectedId = null,
    ViewMode Mode = ViewMode.Focus,
    int Volume = 60,
    double Left = double.NaN,
    double Top = double.NaN,
    double Width = 1280,
    double Height = 720,
    bool Maximized = false,
    double MiniWidth = 320,
    double MiniX = double.NaN,
    double MiniY = double.NaN);

/// <summary>
/// Cameras live in %LocalAppData%\iCamLink\cameras.json with each password protected by DPAPI
/// (current user), same approach NotiLink uses for its paired-device tokens. UI preferences
/// are kept in a separate plain settings.json.
/// </summary>
public sealed class CameraStore
{
    private sealed record StoredCamera(string Id, string Name, string Host, int Port, string Username, string Password);

    // AppSettings.Left/Top default to NaN ("no saved position"); plain System.Text.Json refuses to
    // serialize NaN and would throw on the first Select/Save, so named literals must be allowed.
    private static readonly JsonSerializerOptions SettingsJson = new()
    {
        NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowNamedFloatingPointLiterals,
    };

    private readonly string _dir;
    private string CamerasPath => Path.Combine(_dir, "cameras.json");
    private string SettingsPath => Path.Combine(_dir, "settings.json");

    public CameraStore(string? directory = null)
    {
        _dir = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "iCamLink");
    }

    public List<Camera> LoadCameras()
    {
        try
        {
            if (!File.Exists(CamerasPath)) return new();
            var stored = JsonSerializer.Deserialize<List<StoredCamera>>(File.ReadAllText(CamerasPath)) ?? new();
            return stored.Select(s => new Camera(s.Id, s.Name, s.Host, s.Port, s.Username, Unprotect(s.Password))).ToList();
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            return new();
        }
    }

    public void SaveCameras(IEnumerable<Camera> cameras)
    {
        Directory.CreateDirectory(_dir);
        var stored = cameras.Select(c => new StoredCamera(c.Id, c.Name, c.Host, c.Port, c.Username, Protect(c.Password)));
        File.WriteAllText(CamerasPath, JsonSerializer.Serialize(stored));
    }

    public AppSettings LoadSettings()
    {
        try
        {
            return File.Exists(SettingsPath)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), SettingsJson) ?? new AppSettings()
                : new AppSettings();
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            return new AppSettings();
        }
    }

    public void SaveSettings(AppSettings settings)
    {
        try
        {
            Directory.CreateDirectory(_dir);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings, SettingsJson));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Preferences are best-effort; failing to persist them must never take the UI down.
        }
    }

    private static string Protect(string value) =>
        Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));

    private static string Unprotect(string value)
    {
        try
        {
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser));
        }
        catch (Exception ex) when (ex is CryptographicException or FormatException)
        {
            return string.Empty;
        }
    }
}
