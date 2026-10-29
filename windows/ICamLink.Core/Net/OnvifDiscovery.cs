using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace ICamLink.Core.Net;

/// <param name="Onvif">True when it answered WS-Discovery or has the ONVIF port (2020) open; false = only RTSP (554).</param>
public sealed record DiscoveredCamera(string Host, string? Name, bool Onvif);

public sealed class NoLocalNetworkException : Exception
{
    public NoLocalNetworkException() : base("No hay conexión a una red local.") { }
}

/// <summary>
/// Finds ONVIF cameras: a WS-Discovery multicast probe (UDP 3702) runs alongside a /24 sweep for
/// Tapo's ONVIF port (2020) and the RTSP port (554), since some routers block multicast.
/// Every active IPv4 interface is used (VPN/virtual adapters without a gateway are skipped).
/// </summary>
public sealed class OnvifDiscovery
{
    private const int WsDiscoveryPort = 3702;
    private const int WsWindowMs = 4000;
    private const int OnvifPort = 2020;
    private const int RtspPort = 554;
    private const int PortTimeoutMs = 600;

    private static readonly Regex XAddrs = new(@"XAddrs>\s*([^<]+)<", RegexOptions.Compiled);
    private static readonly Regex HostInUrl = new(@"https?://(\d{1,3}(?:\.\d{1,3}){3})", RegexOptions.Compiled);
    private static readonly Regex ScopeName = new(@"onvif://www\.onvif\.org/name/([^\s<]+)", RegexOptions.Compiled);
    private static readonly Regex ScopeHardware = new(@"onvif://www\.onvif\.org/hardware/([^\s<]+)", RegexOptions.Compiled);

    public async Task ScanAsync(Action<IReadOnlyList<DiscoveredCamera>, double> onUpdate, CancellationToken ct)
    {
        var locals = LocalAddresses();
        if (locals.Count == 0) throw new NoLocalNetworkException();

        var found = new ConcurrentDictionary<string, DiscoveredCamera>();
        var localSet = locals.Select(l => l.ToString()).ToHashSet();
        var done = 0;
        var wsDone = false;
        var total = 254 * locals.Select(PrefixOf).Distinct().Count();

        void Publish()
        {
            var progress = Math.Min(1.0, Volatile.Read(ref done) / (double)total * 0.85 + (wsDone ? 0.15 : 0));
            onUpdate(found.Values.OrderBy(c => IpKey(c.Host)).ToList(), progress);
        }

        var ws = Task.Run(async () =>
        {
            await Task.WhenAll(locals.Select(ip => WsDiscoveryAsync(ip, found, Publish, ct)));
            wsDone = true;
            Publish();
        }, ct);

        using var gate = new SemaphoreSlim(64);
        var sweep = locals.Select(PrefixOf).Distinct().SelectMany(prefix => Enumerable.Range(1, 254).Select(async i =>
        {
            var host = $"{prefix}.{i}";
            try
            {
                if (localSet.Contains(host)) return;
                await gate.WaitAsync(ct);
                try
                {
                    var onvif = await PortOpenAsync(host, OnvifPort, ct);
                    if (onvif || await PortOpenAsync(host, RtspPort, ct))
                        found.AddOrUpdate(host, new DiscoveredCamera(host, null, onvif),
                            (_, old) => old with { Onvif = old.Onvif || onvif });
                }
                finally { gate.Release(); }
            }
            catch (OperationCanceledException) { }
            finally
            {
                if (Interlocked.Increment(ref done) % 8 == 0) Publish();
            }
        })).ToList();

        await Task.WhenAll(sweep);
        await ws;
        ct.ThrowIfCancellationRequested();
        Publish();
    }

    private static async Task WsDiscoveryAsync(IPAddress local, ConcurrentDictionary<string, DiscoveredCamera> found, Action onFound, CancellationToken ct)
    {
        try
        {
            using var udp = new UdpClient(new IPEndPoint(local, 0));
            var probe = Encoding.UTF8.GetBytes(ProbeXml());
            var group = new IPEndPoint(IPAddress.Parse("239.255.255.250"), WsDiscoveryPort);
            using var window = CancellationTokenSource.CreateLinkedTokenSource(ct);
            window.CancelAfter(WsWindowMs);

            var sender = Task.Run(async () =>
            {
                while (!window.IsCancellationRequested)
                {
                    await udp.SendAsync(probe, group, window.Token);
                    await Task.Delay(1500, window.Token);
                }
            }, window.Token);

            try
            {
                while (!window.IsCancellationRequested)
                {
                    var result = await udp.ReceiveAsync(window.Token);
                    var text = Encoding.UTF8.GetString(result.Buffer);
                    var host = XAddrs.Match(text) is { Success: true } x && HostInUrl.Match(x.Groups[1].Value) is { Success: true } h
                        ? h.Groups[1].Value
                        : result.RemoteEndPoint.Address.ToString();
                    var name = ScopeName.Match(text) is { Success: true } n ? Uri.UnescapeDataString(n.Groups[1].Value)
                        : ScopeHardware.Match(text) is { Success: true } hw ? Uri.UnescapeDataString(hw.Groups[1].Value)
                        : null;
                    found.AddOrUpdate(host, new DiscoveredCamera(host, name, true),
                        (_, old) => old with { Name = old.Name ?? name, Onvif = true });
                    onFound();
                }
            }
            catch (OperationCanceledException) { }
            try { await sender; } catch (OperationCanceledException) { }
        }
        catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
        {
            // This interface can't do multicast; the port sweep still covers it.
        }
    }

    private static async Task<bool> PortOpenAsync(string host, int port, CancellationToken ct)
    {
        try
        {
            using var client = new TcpClient();
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(PortTimeoutMs);
            await client.ConnectAsync(host, port, cts.Token);
            return true;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception) { return false; }
    }

    private static List<IPAddress> LocalAddresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up
                        && n.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                        && n.GetIPProperties().GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork))
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address)
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork)
            .ToList();

    private static string PrefixOf(IPAddress ip) => string.Join('.', ip.ToString().Split('.').Take(3));

    private static long IpKey(string ip) =>
        ip.Split('.').Aggregate(0L, (acc, part) => acc * 256 + (long.TryParse(part, out var v) ? v : 0));

    private static string ProbeXml() => $"""
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:{Guid.NewGuid()}</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>
        """;
}
