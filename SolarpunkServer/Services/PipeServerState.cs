using System.Text.RegularExpressions;
using Solarpunk.Protocol;
using Microsoft.Extensions.Logging;

namespace SolarpunkServer.Services;

/// <summary>
/// Shared state for the active plugin connection. Single-writer, multi-reader.
/// Solarpunk's design is one plugin connection per SolarpunkServer instance.
/// </summary>
public sealed class PipeServerState
{
    private readonly ILogger<PipeServerState> _log;
    private readonly object _gate = new();

    private PipeConnection? _connection;

    public PipeServerState(ILogger<PipeServerState> log) => _log = log;

    public PipeConnection? Connection
    {
        get { lock (_gate) return _connection; }
    }

    public void SetConnection(PipeConnection? connection)
    {
        lock (_gate) _connection = connection;
    }

    public DateTimeOffset? LastHeartbeatAt { get; set; }

    public int LastReportedPlayerCount { get; set; }

    public int EffectivePlayerCount => Players.Count;

    public bool HasFreshHeartbeat(TimeSpan maxAge)
    {
        var conn = Connection;
        var last = LastHeartbeatAt;
        if (conn is null || last is null) return false;
        return DateTimeOffset.UtcNow - last.Value <= maxAge;
    }

    // Native plugin reports auth state on every heartbeat (SolarpunkPlugin.dll).
    // Password enforcement is Lua-only and the supervisor emits
    // ServerPassword="" to plugin-config.json, so the expected steady-state
    // on every endpoint is Configured=0/Ready=0.
    // HeartbeatWatchdogService.CheckServerPasswordReady fail-closes if
    // it ever sees Configured=1 — that indicates a stale plugin config or a
    // manually-edited plugin-config.json, both of which can reproduce the
    // game crash loop if they race with the Lua gate. The legacy-plugin case
    // (both fields stay 0) is now the normal case.
    public int LastServerPasswordConfigured { get; set; }
    public int LastServerPasswordHookReady { get; set; }

    // Cached player list shipped by the SolarpunkRoster Lua mod via roster.json
    // (RosterFileWatcherService). SourceQueryHostedService + the launcher's
    // HTTP /players endpoint read from this.
    //
    // The roster is AUTHORITATIVE whenever it has entries: its names are the
    // launcher character names (auth token stripped, identical to the save
    // key derivation). The log-tail entries (_logPlayers) are a fallback for
    // the roster-mod-down case only — merging the two double-counted every
    // player whose log-derived name was the OSS Null machine identity
    // (e.g. RYZEN3-PC-<hex>), which is also what leaked machine names into
    // the A2S player list while /api/v1's roster row was already clean.
    private List<PlayerSnapshot> _players = new();
    private readonly Dictionary<string, PlayerSnapshot> _logPlayers = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _playersGate = new();
    public IReadOnlyList<PlayerSnapshot> Players
    {
        get
        {
            lock (_playersGate)
            {
                if (_players.Count > 0) return _players.ToList();
                // Fallback path: machine-shaped OSS Null identities are
                // connection plumbing, never display names.
                return _logPlayers.Values
                    .Where(p => !PlayerNameHeuristics.IsGeneratedPlayerName(p.DisplayName ?? ""))
                    .ToList();
            }
        }
    }
    public void SetPlayers(IEnumerable<PlayerSnapshot> players)
    {
        lock (_playersGate) _players = players?.ToList() ?? new();
    }

    public void UpsertLogPlayer(string solarpunkUserId, string displayName, int pingMs = 0)
    {
        if (string.IsNullOrWhiteSpace(displayName)) return;
        var id = string.IsNullOrWhiteSpace(solarpunkUserId) ? $"sp:{displayName}" : solarpunkUserId;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        lock (_playersGate)
        {
            var connectedAt = _logPlayers.TryGetValue(id, out var existing)
                ? existing.ConnectedAtUnixMs
                : now;
            _logPlayers[id] = new PlayerSnapshot(id, displayName, connectedAt, now, pingMs);
        }
    }

    public void RemoveLogPlayer(string solarpunkUserId)
    {
        if (string.IsNullOrWhiteSpace(solarpunkUserId)) return;
        lock (_playersGate)
        {
            _logPlayers.Remove(solarpunkUserId);
            _players = _players
                .Where(player => !string.Equals(player.SolarpunkUserId, solarpunkUserId, StringComparison.OrdinalIgnoreCase))
                .ToList();
        }
    }

    public void RemoveLogPlayerByDisplayName(string displayName)
    {
        if (string.IsNullOrWhiteSpace(displayName)) return;
        lock (_playersGate)
        {
            foreach (var key in _logPlayers
                         .Where(kv => string.Equals(kv.Value.DisplayName, displayName, StringComparison.OrdinalIgnoreCase))
                         .Select(kv => kv.Key)
                         .ToList())
            {
                _logPlayers.Remove(key);
            }
            _players = _players
                .Where(player => !string.Equals(player.DisplayName, displayName, StringComparison.OrdinalIgnoreCase))
                .ToList();
        }
    }

    public void ClearLogPlayers()
    {
        lock (_playersGate) _logPlayers.Clear();
    }

    internal void SetLogPlayerForTest(PlayerSnapshot player)
    {
        lock (_playersGate) _logPlayers[player.SolarpunkUserId] = player;
    }

    public void ClearLogPlayersIfOnlyOne()
    {
        lock (_playersGate)
        {
            var mergedCount = _players
                .Concat(_logPlayers.Values)
                .GroupBy(player => !string.IsNullOrWhiteSpace(player.DisplayName)
                    ? $"name:{player.DisplayName}"
                    : $"id:{player.SolarpunkUserId}", StringComparer.OrdinalIgnoreCase)
                .Count();
            if (mergedCount <= 1)
            {
                _logPlayers.Clear();
                _players.Clear();
            }
        }
    }

}

/// <summary>
/// Shared player-name heuristics. Under OSS=Null the engine derives the
/// player name from the client machine name — those are connection plumbing,
/// not display names; the launcher's ?Name=&lt;charname&gt; is the real identity.
/// Shape contract is byte-identical with the Lua mods' is_phantom_name
/// (SolarpunkNoPhantomHost): &lt;prefix&gt;-&lt;6+ hex&gt; where the prefix is the literal
/// "server" or an UPPERCASE machine-name shape (e.g. RYZEN3-PC-680B752F44B1A),
/// plus the hosting-provider prefixes the log tail filtered historically.
/// </summary>
internal static class PlayerNameHeuristics
{
    private static readonly Regex MachineShape = new(
        @"^(?<prefix>[A-Za-z0-9_\-]+)-(?<hex>[0-9A-Fa-f]{6,})$",
        RegexOptions.Compiled);

    private static readonly Regex UppercasePrefix = new(
        @"^[A-Z0-9_\-]+$",
        RegexOptions.Compiled);

    public static bool IsGeneratedPlayerName(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return false;
        value = value.Trim();
        if (value.StartsWith("ns", StringComparison.OrdinalIgnoreCase)
            || value.StartsWith("WIN-", StringComparison.OrdinalIgnoreCase)
            || value.StartsWith("DESKTOP-", StringComparison.OrdinalIgnoreCase)
            || value.StartsWith("LAPTOP-", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        var m = MachineShape.Match(value);
        if (!m.Success) return false;
        var prefix = m.Groups["prefix"].Value;
        return prefix.Equals("server", StringComparison.Ordinal)
               || UppercasePrefix.IsMatch(prefix);
    }
}

/// <summary>
/// Wraps the per-plugin connection: send queue, sequence counter, codec.
/// </summary>
public sealed class PipeConnection
{
    private readonly FrameCodec _codec;
    private readonly Func<byte[], CancellationToken, Task> _write;
    private uint _sequence;

    public PipeConnection(string instanceId, int pluginPid, string pluginVersion, FrameCodec codec, Func<byte[], CancellationToken, Task> write)
    {
        InstanceId = instanceId;
        PluginPid = pluginPid;
        PluginVersion = pluginVersion;
        _codec = codec;
        _write = write;
    }

    public string InstanceId { get; }
    public int PluginPid { get; }
    public string PluginVersion { get; }
    public DateTimeOffset ConnectedAt { get; } = DateTimeOffset.UtcNow;

    public Task SendAsync<T>(FrameType type, T payload, CancellationToken ct = default)
    {
        var seq = Interlocked.Increment(ref _sequence);
        var bytes = _codec.Encode(type, FrameFlags.None, seq, payload);
        return _write(bytes, ct);
    }
}
