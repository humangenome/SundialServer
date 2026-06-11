using System.Text.RegularExpressions;
using System.Text;
using SolarpunkServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace SolarpunkServer.Services;

/// <summary>
/// Tails the Solarpunk host's UE log file (<c>{GameUserDir}/Saved/Logs/Solarpunk.log</c>),
/// filters for operator-meaningful categories, and re-emits each line
/// through Serilog with a <c>[Solarpunk]</c> source prefix. Joins, leaves,
/// errors, save events, map travels — all show up interleaved with
/// SolarpunkServer's own log stream.
///
/// Also looks for the Solarpunk build banner on the first pass and registers it
/// with <see cref="SolarpunkVersionInfo"/> so A2S responses can publish it.
///
/// Player tracking from the log is the fallback data source for A2S /
/// /api/v1/players; the primary is the roster.json file written by the
/// server-side roster Lua mod (see <see cref="RosterFileWatcherService"/>).
/// All join/leave regexes below are stock UE5 LogNet lines, not
/// game-specific — Solarpunk's BP layer does not emit its own join/leave
/// log lines the way G2's UWE layer did.
/// </summary>
public sealed class SpLogTailService : BackgroundService
{
    private static readonly Regex BuildRegex = new(
        @"LogInit:\s+Build:\s+(?<build>[A-Za-z0-9\-_.+]+)",
        RegexOptions.Compiled);

    private static readonly Regex CategoryRegex = new(
        @"^\[[\d.\-: ]+\]\[\s*\d+\]\s*(?<cat>Log[A-Za-z0-9_]+):",
        RegexOptions.Compiled);

    // Solarpunk log categories worth surfacing on the operator console.
    // Skip FMOD, RHI, Slate, ShaderCompiler, PakFile, IoDispatcher, etc.
    private static readonly HashSet<string> InterestingCategories = new(StringComparer.Ordinal)
    {
        "LogNet",
        "LogNetVersion",
        "LogSaveSystem",
        "LogSaveGame",
        "LogWorld",
        "LogGameMode",
        "LogGameState",
        "LogGameplayMessage",
        "LogOnline",
        "LogLoad",
        "LogExit",
        "LogBlueprintUserMessages",
    };

    private static readonly Regex JoinRegex   = new(
        @"(?:NotifyAcceptingConnection accepted from|Server accepting post-challenge connection from):\s*(?<addr>[^\s,]+)",
        RegexOptions.Compiled);
    private static readonly Regex LeaveRegex  = new(
        @"(?:UNetConnection::Close|UNetConnection::Tick: Connection TIMED OUT|UChannel::Close|UChannel::CleanUp).*RemoteAddr:\s*(?<addr>[^\s,]+)|UNetDriver::RemoveClientConnection - Removed address\s+(?<addr2>[^\s,]+)",
        RegexOptions.Compiled);
    private static readonly Regex TravelRegex = new(@"UEngine::Browse Started Browse:\s*""(?<url>[^""]+)""",    RegexOptions.Compiled);
    private static readonly Regex LoginRequestRegex = new(
        @"LogNet:\s+Login request:\s+\?Name=(?<name>[^?\s]+).*?(?:\?PlayerId=(?<player>[^?\s]+))?",
        RegexOptions.Compiled);
    private static readonly Regex JoinSucceededRegex = new(
        @"LogNet:\s+Join succeeded:\s*(?<name>.+?)\s*$",
        RegexOptions.Compiled);
    private static readonly Regex LogoutRegex = new(
        @"LogGameMode:\s+.*Logout.*|LogNet:\s+.*connection closed",
        RegexOptions.Compiled);

    private readonly ILogger<SpLogTailService> _log;
    private readonly SolarpunkServerOptions _opts;
    private readonly PipeServerState _state;
    private readonly Queue<string> _pendingAddresses = new();
    private readonly Dictionary<string, PendingLogin> _pendingLogins = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _playerIdByAddress = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _playerNameByAddress = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _playerGate = new();
    private long _position;
    private string? _lastBuildLogged;
    private bool _tailReadyForPlayerEvents;

    public SpLogTailService(ILogger<SpLogTailService> log, IOptions<SolarpunkServerOptions> opts, PipeServerState state)
    {
        _log = log;
        _opts = opts.Value;
        _state = state;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_opts.GameUserDir))
        {
            _log.LogInformation("[Solarpunk] log tail idle: GameUserDir not configured");
            return;
        }
        var logPath = Path.Combine(_opts.GameUserDir, "Saved", "Logs", "Solarpunk.log");
        _log.LogInformation("[Solarpunk] log tail watching {Path}", logPath);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (!File.Exists(logPath))
                {
                    await Task.Delay(2000, ct).ConfigureAwait(false);
                    continue;
                }
                if (!_tailReadyForPlayerEvents)
                {
                    var catchUpEnd = new FileInfo(logPath).Length;
                    await CatchUpExistingLogAsync(logPath, catchUpEnd, ct).ConfigureAwait(false);
                    _position = catchUpEnd;
                    _tailReadyForPlayerEvents = true;
                    continue;
                }

                using var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                if (fs.Length < _position) _position = 0; // log rotated
                fs.Seek(_position, SeekOrigin.Begin);
                using var sr = new StreamReader(fs);
                string? line;
                while ((line = await sr.ReadLineAsync(ct).ConfigureAwait(false)) is not null)
                {
                    EmitLine(line, trackPlayerEvents: true);
                }
                _position = fs.Position;
            }
            catch (OperationCanceledException) { return; }
            catch (IOException) { /* log got rotated mid-read */ }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "[Solarpunk] log tail loop error");
            }
            try { await Task.Delay(1500, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task CatchUpExistingLogAsync(string logPath, long endPosition, CancellationToken ct)
    {
        if (endPosition <= 0) return;
        if (endPosition > int.MaxValue)
        {
            _log.LogWarning("[Solarpunk] existing log is too large for startup catch-up; starting live tail at EOF");
            return;
        }

        var bytes = new byte[(int)endPosition];
        var read = 0;
        await using (var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            while (read < bytes.Length)
            {
                var chunk = await fs.ReadAsync(bytes.AsMemory(read, bytes.Length - read), ct).ConfigureAwait(false);
                if (chunk <= 0) break;
                read += chunk;
            }
        }

        using var sr = new StringReader(Encoding.UTF8.GetString(bytes, 0, read));
        while (await sr.ReadLineAsync(ct).ConfigureAwait(false) is { } line)
        {
            EmitLine(line, trackPlayerEvents: false);
        }
    }

    private void EmitLine(string line, bool trackPlayerEvents)
    {
        if (string.IsNullOrEmpty(line)) return;

        // Existing logs can survive game updates, so keep the newest build
        // banner seen during the initial catch-up pass instead of pinning the
        // first historical one.
        var m = BuildRegex.Match(line);
        if (m.Success)
        {
            var build = m.Groups["build"].Value;
            SolarpunkVersionInfo.SetSpBuild(build);
            if (!string.Equals(_lastBuildLogged, build, StringComparison.Ordinal))
            {
                _log.LogInformation("[Solarpunk] build detected: {Build}", build);
                _lastBuildLogged = build;
            }
        }

        var catMatch = CategoryRegex.Match(line);
        var cat = catMatch.Success ? catMatch.Groups["cat"].Value : null;
        var isInteresting = cat is not null && InterestingCategories.Contains(cat);
        if (!isInteresting) return;

        // Promote join / leave / travel to dedicated highlight messages.
        if (TryExtractAcceptedAddress(line, out var joinAddress))
        {
            var addr = joinAddress;
            if (trackPlayerEvents) TrackAcceptedAddress(addr);
            _log.LogInformation("[Solarpunk] player connection accepted from {Addr}", addr);
            return;
        }
        var loginMatch = LoginRequestRegex.Match(line);
        if (trackPlayerEvents && loginMatch.Success)
        {
            TrackLoginRequest(loginMatch.Groups["name"].Value, loginMatch.Groups["player"].Value);
        }
        var joinSucceededMatch = JoinSucceededRegex.Match(line);
        if (joinSucceededMatch.Success)
        {
            if (trackPlayerEvents) TrackPlayerJoined(joinSucceededMatch.Groups["name"].Value);
            _log.LogInformation("[Solarpunk] player joined: {Name}", joinSucceededMatch.Groups["name"].Value);
            return;
        }
        if (TryExtractLeaveAddress(line, out var leaveAddress))
        {
            var addr = leaveAddress;
            if (trackPlayerEvents) TrackPlayerLeftByAddress(addr);
            _log.LogInformation("[Solarpunk] connection closed for {Addr}", addr);
            return;
        }
        if (trackPlayerEvents && LogoutRegex.IsMatch(line))
        {
            _log.LogInformation("[Solarpunk] player logout detected");
            return;
        }
        var travelMatch = TravelRegex.Match(line);
        if (travelMatch.Success)
        {
            _log.LogInformation("[Solarpunk] travel -> {Url}", travelMatch.Groups["url"].Value);
            return;
        }

        // Default: pass through with [Solarpunk] prefix and category as info.
        if (line.Contains("Error", StringComparison.OrdinalIgnoreCase))
            _log.LogError("[Solarpunk] {Line}", line);
        else if (line.Contains("Warning", StringComparison.OrdinalIgnoreCase))
            _log.LogWarning("[Solarpunk] {Line}", line);
        else
            _log.LogInformation("[Solarpunk] {Line}", line);
    }

    private void TrackAcceptedAddress(string address)
    {
        if (string.IsNullOrWhiteSpace(address)) return;
        lock (_playerGate)
        {
            if (!_pendingAddresses.Contains(address, StringComparer.OrdinalIgnoreCase))
                _pendingAddresses.Enqueue(address);
            while (_pendingAddresses.Count > 16) _pendingAddresses.Dequeue();
        }
    }

    private void TrackLoginRequest(string displayName, string playerId)
    {
        displayName = CleanName(displayName);
        if (displayName.Length == 0 || IsGeneratedPlayerName(displayName)) return;
        var id = string.IsNullOrWhiteSpace(playerId) ? $"sp:{displayName}" : playerId.Trim();
        string? address = null;
        lock (_playerGate)
        {
            if (_pendingAddresses.Count > 0) address = _pendingAddresses.Dequeue();
            _pendingLogins[displayName] = new PendingLogin(id, displayName, address);
            if (!string.IsNullOrWhiteSpace(address)) _playerIdByAddress[address] = id;
            if (!string.IsNullOrWhiteSpace(address)) _playerNameByAddress[address] = displayName;
        }
    }

    private void TrackPlayerJoined(string displayName)
    {
        displayName = CleanName(displayName);
        if (displayName.Length == 0 || IsGeneratedPlayerName(displayName)) return;
        PendingLogin? pending = null;
        lock (_playerGate)
        {
            if (_pendingLogins.TryGetValue(displayName, out pending))
                _pendingLogins.Remove(displayName);
        }
        var id = pending?.PlayerId ?? $"sp:{displayName}";
        if (!string.IsNullOrWhiteSpace(pending?.Address))
        {
            lock (_playerGate)
            {
                _playerIdByAddress[pending.Address] = id;
                _playerNameByAddress[pending.Address] = displayName;
            }
        }
        _state.UpsertLogPlayer(id, displayName);
    }

    private void TrackPlayerLeftByAddress(string address)
    {
        if (string.IsNullOrWhiteSpace(address)) return;
        string? id = null;
        string? displayName = null;
        lock (_playerGate)
        {
            if (_playerIdByAddress.TryGetValue(address, out id))
                _playerIdByAddress.Remove(address);
            if (_playerNameByAddress.TryGetValue(address, out displayName))
                _playerNameByAddress.Remove(address);
        }
        var removed = false;
        if (!string.IsNullOrWhiteSpace(id))
        {
            _state.RemoveLogPlayer(id);
            removed = true;
        }
        if (!string.IsNullOrWhiteSpace(displayName))
        {
            _state.RemoveLogPlayerByDisplayName(displayName);
            removed = true;
        }
        if (!removed)
            _state.ClearLogPlayersIfOnlyOne();
    }

    private static string CleanName(string value) => value.Trim().Trim('"');

    internal static bool TryExtractAcceptedAddress(string line, out string address)
    {
        address = string.Empty;
        var match = JoinRegex.Match(line);
        if (!match.Success) return false;
        address = match.Groups["addr"].Value.Trim();
        return address.Length > 0;
    }

    internal static bool TryExtractLeaveAddress(string line, out string address)
    {
        address = string.Empty;
        var match = LeaveRegex.Match(line);
        if (!match.Success) return false;
        address = (match.Groups["addr"].Success ? match.Groups["addr"].Value : match.Groups["addr2"].Value).Trim();
        return address.Length > 0;
    }

    // Under OSS=Null the engine derives the player name from the client
    // machine name (e.g. "ns567705-<hash>", "WIN-...", "DESKTOP-...",
    // "LAPTOP-<hex>"). Those are connection plumbing, not display names —
    // the launcher's ?Name=<charname> is the real identity. Filter the
    // machine-shaped ones from the visible roster.
    private static bool IsGeneratedPlayerName(string value)
    {
        return value.StartsWith("ns", StringComparison.OrdinalIgnoreCase)
               || value.StartsWith("WIN-", StringComparison.OrdinalIgnoreCase)
               || value.StartsWith("DESKTOP-", StringComparison.OrdinalIgnoreCase);
    }

    private sealed record PendingLogin(string PlayerId, string DisplayName, string? Address);
}
