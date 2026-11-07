using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using SolarpunkServer.Configuration;
using SolarpunkServer.Services;

namespace SolarpunkServer.Tests;

// The real admin HTTP service on a free port, bound to all interfaces, for tests that need the
// listener itself (what is read before the signature is checked, what one address may do).
internal sealed class HttpLiveHarness : IAsyncDisposable
{
    public const string Password = "live-test-secret";

    private readonly string _root;
    private readonly SolarpunkHttpService _service;
    private readonly SaveOrchestratorService _saves;
    public int Port { get; }
    public byte[] Key { get; }
    public string SaveDir { get; }

    private HttpLiveHarness(string root, SolarpunkHttpService service, SaveOrchestratorService saves, int port, byte[] key, string saveDir)
    {
        _root = root; _service = service; _saves = saves; Port = port; Key = key; SaveDir = saveDir;
    }

    public static async Task<HttpLiveHarness> StartAsync(ILogger<SolarpunkHttpService>? log = null)
    {
        var root = Path.Combine(Path.GetTempPath(), "sp-http-live-" + Guid.NewGuid().ToString("N"));
        var port = FreePort();
        var opts = new SolarpunkServerOptions
        {
            HttpPort = port,
            RconPassword = Password,
            HmacKeyPath = Path.Combine(root, "data", "hmac.key"),
            SaveDir = Path.Combine(root, "saves"),
            InstanceId = "live-test",
            MaxUploadBytes = 64L * 1024 * 1024,
            SnapshotsEnabled = false,
        };
        Directory.CreateDirectory(Path.Combine(root, "data"));
        Directory.CreateDirectory(opts.SaveDir);
        var o = Options.Create(opts);
        var pipe = new PipeServerState(NullLogger<PipeServerState>.Instance);
        var saves = new SaveOrchestratorService(NullLogger<SaveOrchestratorService>.Instance, o, pipe,
            new SpRestartCoordinator(NullLogger<SpRestartCoordinator>.Instance, o));
        var chat = new ChatService(NullLogger<ChatService>.Instance, new FixedMonitor(opts));
        var service = new SolarpunkHttpService(
            log ?? NullLogger<SolarpunkHttpService>.Instance, o, new ConfigurationBuilder().Build(), saves, pipe,
            new InstanceIdentityProvider(o), chat);
        await service.StartAsync(CancellationToken.None);
        var h = new HttpLiveHarness(root, service, saves, port, SHA256.HashData(Encoding.UTF8.GetBytes(Password)), opts.SaveDir);
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        for (var i = 0; i < 50; i++)
        {
            try { await http.GetAsync($"http://127.0.0.1:{port}/api/v1/players"); return h; }
            catch { await Task.Delay(100); }
        }
        await h.DisposeAsync();
        throw new InvalidOperationException("listener never came up");
    }

    public static string[] UploadTempFiles()
    {
        var dir = Path.Combine(Path.GetTempPath(), "solarpunk-uploads");
        return Directory.Exists(dir) ? Directory.GetFiles(dir) : Array.Empty<string>();
    }

    public static string Sha(byte[] body) => Convert.ToHexString(SHA256.HashData(body)).ToLowerInvariant();

    public async Task<int> SignedAsync(string method, string path, byte[] body, bool sendSha, long? ts = null,
        IPAddress? from = null, byte[]? signKey = null)
    {
        var t = ts ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var sha = Sha(body);
        var sig = HmacRequestAuth.Sign(signKey ?? Key, HmacRequestAuth.CanonicalString(method, path.Split('?')[0], t, sha));
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        using var req = new HttpRequestMessage(new HttpMethod(method), $"http://{from ?? IPAddress.Loopback}:{Port}{path}");
        req.Headers.Add(AdminRequestGate.TimestampHeader, t.ToString());
        req.Headers.Add(AdminRequestGate.SignatureHeader, sig);
        if (sendSha) req.Headers.Add(AdminRequestGate.ContentShaHeader, sha);
        if (body.Length > 0) req.Content = new ByteArrayContent(body);
        try
        {
            using var resp = await http.SendAsync(req);
            return (int)resp.StatusCode;
        }
        catch (HttpRequestException ex) when (ex.InnerException is IOException or SocketException)
        {
            // The server answered and closed before the whole body was sent (a refused upload).
            return -1;
        }
    }

    public async ValueTask DisposeAsync()
    {
        try { await _service.StopAsync(CancellationToken.None); } catch { }
        _service.Dispose();
        try { await _saves.StopAsync(CancellationToken.None); } catch { }
        _saves.Dispose();
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var p = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return p;
    }

    private sealed class FixedMonitor : IOptionsMonitor<SolarpunkServerOptions>
    {
        public FixedMonitor(SolarpunkServerOptions v) => CurrentValue = v;
        public SolarpunkServerOptions CurrentValue { get; }
        public SolarpunkServerOptions Get(string? name) => CurrentValue;
        public IDisposable? OnChange(Action<SolarpunkServerOptions, string?> listener) => null;
    }
}
