using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace ICamLink.Core.Net;

public sealed record ProbeResult(bool Ok, string Message)
{
    public static readonly ProbeResult Success = new(true, "Conexión exitosa: el flujo RTSP responde.");
    public static readonly ProbeResult BadCredentials = new(false, "Usuario o contraseña RTSP incorrectos.");
    public static readonly ProbeResult NotFound = new(false, "La cámara respondió, pero no existe la ruta /stream2.");
    public static readonly ProbeResult Unreachable = new(false, "No se pudo alcanzar la cámara (revisa IP, puerto y red).");
    public static ProbeResult Failure(string detail) => new(false, $"Error: {detail}");
}

/// <summary>
/// Connection test using a bare RTSP DESCRIBE (Digest/Basic) on the sub stream. It tells apart
/// bad credentials from an unreachable host, and the socket is closed right away so it doesn't
/// keep a camera slot busy the way a real player would.
/// </summary>
public static class RtspProbe
{
    private const int ConnectMs = 3000;
    private const int ReadMs = 4000;

    public static async Task<ProbeResult> ProbeAsync(string host, int port, string user, string pass)
    {
        var uri = $"rtsp://{host}:{port}/stream2";
        try
        {
            var (code, headers) = await DescribeAsync(host, port, uri, null);
            switch (code)
            {
                case 200: return ProbeResult.Success;
                case 404: return ProbeResult.NotFound;
                case 401:
                    var auth = AuthHeader(headers, uri, user, pass);
                    if (auth == null) return ProbeResult.Failure("método de autenticación no soportado");
                    var (second, _) = await DescribeAsync(host, port, uri, auth);
                    return second switch
                    {
                        200 => ProbeResult.Success,
                        401 or 403 => ProbeResult.BadCredentials,
                        404 => ProbeResult.NotFound,
                        _ => ProbeResult.Failure($"respuesta RTSP {second}"),
                    };
                default: return ProbeResult.Failure($"respuesta RTSP {code}");
            }
        }
        catch (Exception ex) when (ex is SocketException or TimeoutException or OperationCanceledException)
        {
            return ProbeResult.Unreachable;
        }
        catch (Exception ex)
        {
            return ProbeResult.Failure(ex.Message);
        }
    }

    private static async Task<(int Code, List<string> Headers)> DescribeAsync(string host, int port, string uri, string? auth)
    {
        using var client = new TcpClient();
        using (var connectCts = new CancellationTokenSource(ConnectMs))
            await client.ConnectAsync(host, port, connectCts.Token);

        var stream = client.GetStream();
        var request = new StringBuilder()
            .Append($"DESCRIBE {uri} RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\nUser-Agent: iCamLink\r\n");
        if (auth != null) request.Append($"Authorization: {auth}\r\n");
        request.Append("\r\n");
        var bytes = Encoding.ASCII.GetBytes(request.ToString());

        using var cts = new CancellationTokenSource(ReadMs);
        await stream.WriteAsync(bytes, cts.Token);

        using var reader = new StreamReader(stream, Encoding.Latin1);
        var status = await reader.ReadLineAsync(cts.Token) ?? throw new IOException("sin respuesta");
        var parts = status.Split(' ');
        if (parts.Length < 2 || !int.TryParse(parts[1], out var code)) throw new IOException("respuesta inválida");

        var headers = new List<string>();
        while (await reader.ReadLineAsync(cts.Token) is { Length: > 0 } line) headers.Add(line);
        return (code, headers);
    }

    private static readonly Regex Param = new("""(\w+)=(?:"([^"]*)"|([^,\s]*))""", RegexOptions.Compiled);

    private static string? AuthHeader(List<string> headers, string uri, string user, string pass)
    {
        var challenges = headers
            .Where(h => h.StartsWith("WWW-Authenticate:", StringComparison.OrdinalIgnoreCase))
            .Select(h => h[(h.IndexOf(':') + 1)..].Trim())
            .ToList();

        var digest = challenges.FirstOrDefault(c => c.StartsWith("Digest", StringComparison.OrdinalIgnoreCase));
        if (digest != null)
        {
            var args = digest[(digest.IndexOf(' ') + 1)..];
            var p = Param.Matches(args).ToDictionary(
                m => m.Groups[1].Value.ToLowerInvariant(),
                m => m.Groups[2].Success ? m.Groups[2].Value : m.Groups[3].Value);
            if (!p.TryGetValue("nonce", out var nonce)) return null;
            p.TryGetValue("realm", out var realm);
            realm ??= "";
            var ha1 = Md5($"{user}:{realm}:{pass}");
            var ha2 = Md5($"DESCRIBE:{uri}");
            var qop = p.TryGetValue("qop", out var q)
                ? q.Split(',').Select(s => s.Trim()).FirstOrDefault(s => s == "auth")
                : null;
            const string nc = "00000001";
            var cnonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
            var response = qop != null ? Md5($"{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}") : Md5($"{ha1}:{nonce}:{ha2}");
            var header = $"Digest username=\"{user}\", realm=\"{realm}\", nonce=\"{nonce}\", uri=\"{uri}\", response=\"{response}\"";
            return qop != null ? $"{header}, qop={qop}, nc={nc}, cnonce=\"{cnonce}\"" : header;
        }
        if (challenges.Any(c => c.StartsWith("Basic", StringComparison.OrdinalIgnoreCase)))
            return "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes($"{user}:{pass}"));
        return null;
    }

    private static string Md5(string s) =>
        Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(s))).ToLowerInvariant();
}
