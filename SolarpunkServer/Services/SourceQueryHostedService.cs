using Solarpunk.SourceQuery;
using SolarpunkServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace SolarpunkServer.Services;

/// <summary>
/// Runs the Source A2S query responder. Pulls live snapshot data from the plugin
/// (via <see cref="PipeServerState"/>) on every query, so external tools like
/// GameTracker and ServerMonkey see real player counts.
/// </summary>
public sealed class SourceQueryHostedService : IHostedService, IAsyncDisposable
{
    private readonly ILogger<SourceQueryHostedService> _log;
    private readonly SolarpunkServerOptions _opts;
    private readonly PipeServerState _state;
    private readonly TimeSpan _heartbeatTimeout;
    private SourceQueryServer? _server;

    public SourceQueryHostedService(
        ILogger<SourceQueryHostedService> log,
        IOptions<SolarpunkServerOptions> opts,
        PipeServerState state)
    {
        _log = log;
        _opts = opts.Value;
        _state = state;
        _heartbeatTimeout = TimeSpan.FromSeconds(Math.Max(1, _opts.PluginHeartbeatTimeoutSeconds));
    }

    public Task StartAsync(CancellationToken ct)
    {
        _server = new SourceQueryServer(
            _opts.QueryPort,
            BuildInfo,
            BuildPlayers,
            BuildRules,
            IsGameOnline,
            queryObserver: (type, remote) => _log.LogDebug("A2S query {Type} from {Remote}", type, remote));
        _log.LogInformation("Source A2S query listening on UDP {Port}", _server.BoundPort);
        return _server.StartAsync(ct);
    }

    public async Task StopAsync(CancellationToken _)
    {
        if (_server is not null) await _server.StopAsync().ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (_server is not null) await _server.StopAsync().ConfigureAwait(false);
    }

    private ServerInfoSnapshot BuildInfo() => new(
        Name: string.IsNullOrWhiteSpace(_opts.ServerName) ? $"Solarpunk — {_opts.InstanceId}" : _opts.ServerName.Trim(),
        Map: "MainLevel",
        Folder: "solarpunk",
        Game: "Solarpunk",
        SteamAppId: 1805110,                          // real Steam AppID — written as 64-bit GameID in EDF
        PlayerCount: _state.EffectivePlayerCount,
        MaxPlayers: _opts.MaxPlayers,
        // Reflect the Lua-side SolarpunkAuth gate's configured password.
        // SolarpunkAuthPassword is the field the panel populates and that
        // SolarpunkAuth.lua actually enforces. The legacy ServerPassword
        // field is intentionally ignored here for consistency with
        // SolarpunkAuth.lua, which dropped the legacy fallback (reading
        // ServerPassword would only matter for the native-enforcement
        // crash path we're pivoting away from).
        PasswordRequired: !string.IsNullOrEmpty(_opts.SolarpunkAuthPassword),
        VacSecured: false,
        Version: $"solarpunk-{SolarpunkVersionInfo.SolarpunkVersion}/sp-{SolarpunkVersionInfo.SpBuild}",
        GameplayPort: _opts.GameplayPort,
        Keywords: $"solarpunk,sp,solarpunk={SolarpunkVersionInfo.SolarpunkVersion},spbuild={SolarpunkVersionInfo.SpBuild}");

    private IReadOnlyList<PlayerInfoEntry> BuildPlayers()
    {
        // Source A2S player list. We populate from cached
        // PlayerListSnapshot frames the plugin ships over IPC. Each
        // entry maps to (DisplayName, Score=0, ConnectionSeconds since
        // ConnectedAtUnixMs). If the plugin hasn't sent a snapshot yet
        // (or no players are connected) the list is empty — gametracker
        // / panel tools show 'no players online' rather than a faked
        // count.
        var snap = _state.Players;
        if (snap.Count == 0) return Array.Empty<PlayerInfoEntry>();

        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var result = new List<PlayerInfoEntry>(snap.Count);
        foreach (var p in snap)
        {
            var ageMs = nowMs - p.ConnectedAtUnixMs;
            var ageSec = ageMs > 0 ? (float)(ageMs / 1000.0) : 0f;
            result.Add(new PlayerInfoEntry(
                Name: string.IsNullOrEmpty(p.DisplayName) ? p.SolarpunkUserId : p.DisplayName,
                Score: 0,
                ConnectSeconds: ageSec));
        }
        return result;
    }

    private IReadOnlyList<KeyValuePair<string, string>> BuildRules() => new[]
    {
        new KeyValuePair<string, string>("instance", _opts.InstanceId),
        new KeyValuePair<string, string>("gameplay_port", _opts.GameplayPort.ToString()),
        new KeyValuePair<string, string>("solarpunk_version", SolarpunkVersionInfo.SolarpunkVersion),
        new KeyValuePair<string, string>("sp_build", SolarpunkVersionInfo.SpBuild),
    };

    // Online only when the game process is alive and the Lua runtime/host stack
    // is publishing fresh ready/hosting status. The native pipe heartbeat is
    // diagnostic on Solarpunk servers; the identity DLL is client-side.
    private bool IsGameOnline()
    {
        var freshHeartbeat = _state.HasFreshHeartbeat(_heartbeatTimeout);
        var processAlive = string.IsNullOrWhiteSpace(_opts.GamePidFile) || GameProcessProbe.IsAlive(_opts.GamePidFile);
        var runtimeStatus = ReadStatusFile(".solarpunk-runtime-status");
        var hostStatus = ReadStatusFile(".solarpunk-host-status");
        var statusTimeout = TimeSpan.FromSeconds(Math.Max(60, _opts.PluginHeartbeatTimeoutSeconds * 3));
        var runtimeReady = IsStatusFlagSet(runtimeStatus, "ready") && IsStatusFresh(runtimeStatus, statusTimeout);
        var hostReady = IsStatusFlagSet(hostStatus, "hosting") && IsStatusFresh(hostStatus, statusTimeout);
        var online = processAlive && runtimeReady && hostReady;
        _log.LogDebug(
            "A2S IsGameOnline={Online} (freshHeartbeat={Heartbeat}, gameProcessAlive={Process}, runtimeReady={RuntimeReady}, hostReady={HostReady})",
            online, freshHeartbeat, processAlive, runtimeReady, hostReady);
        return online;
    }

    private static Dictionary<string, string> ReadStatusFile(string fileName)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, fileName);
            if (!File.Exists(path)) return result;
            foreach (var line in File.ReadAllLines(path))
            {
                var eq = line.IndexOf('=');
                if (eq <= 0) continue;
                result[line[..eq].Trim()] = line[(eq + 1)..].Trim();
            }
        }
        catch
        {
            result.Clear();
        }
        return result;
    }

    private static bool IsStatusFlagSet(IReadOnlyDictionary<string, string> status, string key) =>
        status.TryGetValue(key, out var value) && value == "1";

    private static bool IsStatusFresh(IReadOnlyDictionary<string, string> status, TimeSpan maxAge)
    {
        if (!status.TryGetValue("updated", out var raw) || !long.TryParse(raw, out var unixSeconds))
            return false;
        try
        {
            var updated = DateTimeOffset.FromUnixTimeSeconds(unixSeconds);
            var age = DateTimeOffset.UtcNow - updated;
            return age >= TimeSpan.Zero && age <= maxAge;
        }
        catch
        {
            return false;
        }
    }
}
