using Solarpunk.Protocol;
using Solarpunk.Rcon;
using Solarpunk.Persistence;
using SolarpunkServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.IO;
using System.Linq;
using System.Text;

namespace SolarpunkServer.Services;

/// <summary>
/// Source RCON server. Translates RCON commands into <see cref="FrameType.RconCommand"/>
/// frames sent to the plugin and awaits the matching response, with a fallback
/// for purely server-side commands (status, players, save).
/// </summary>
public sealed class RconHostedService : IHostedService
{
    private readonly ILogger<RconHostedService> _log;
    private readonly SolarpunkServerOptions _opts;
    private readonly PipeServerState _state;
    private readonly SaveOrchestratorService _saves;
    private readonly ChatService _chat;
    private RconServer? _server;

    public RconHostedService(
        ILogger<RconHostedService> log,
        IOptions<SolarpunkServerOptions> opts,
        PipeServerState state,
        SaveOrchestratorService saves,
        ChatService chat)
    {
        _log = log;
        _opts = opts.Value;
        _state = state;
        _saves = saves;
        _chat = chat;
    }

    public Task StartAsync(CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_opts.RconPassword))
        {
            _log.LogWarning("RCON disabled (no password set in Solarpunk:RconPassword)");
            return Task.CompletedTask;
        }
        _server = new RconServer(_opts.RconPort, _opts.RconPassword, ExecuteAsync, _log);
        _server.Start(ct);
        _log.LogInformation("RCON listening on TCP {Port}", _server.BoundPort);
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken _)
    {
        if (_server is not null) await _server.StopAsync().ConfigureAwait(false);
    }

    private async Task<string> ExecuteAsync(string command)
    {
        var trimmed = command.Trim();
        if (string.IsNullOrEmpty(trimmed)) return "";

        var parts = trimmed.Split(' ', 2);
        var head = parts[0].ToLowerInvariant();
        var rest = parts.Length > 1 ? parts[1] : "";
        // Log the verb + arg length only — never the raw arg, which may carry
        // chat text or operator-entered content.
        _log.LogDebug("RCON dispatch: cmd={Cmd} argLen={ArgLen}", head, rest.Length);
        return head switch
        {
            "help"     => HelpText,
            "status"   => BuildStatus(),
            "players"  => BuildPlayers(),
            "ping"     => "pong",
            "save"     => await HandleSaveAsync(rest).ConfigureAwait(false),
            "snapshot" => await HandleSaveAsync("snapshot").ConfigureAwait(false),
            "say"      => HandleChat(rest, "system"),
            "announce" => HandleChat(rest, "admin"),
            "motd"     => HandleMotd(rest),
            "kick"     => await HandleKickAsync(rest).ConfigureAwait(false),
            "ban"      => HandleBan(rest),
            "unban"    => HandleUnban(rest),
            "bans"     => HandleBans(),
            _          => $"unknown rcon command: {head} (try: help)",
        };
    }

    private static long NowUnix() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    internal const string HelpText =
        "commands: status, players, ping, save snapshot, save list, say <msg>, announce <msg>, motd [msg], " +
        "kick <player|id>, ban <player|id> [reason], unban <id>, bans (a name with spaces goes in quotes)";

    // An account id: the Epic product user id the game keeps for a player who joined by invite
    // code (32 hex characters, SkyGamePlayerState.SkyGameNativeId). The roster publishes it as that
    // player's SolarpunkUserId, so bans and kicks key on it and two players who share a name stay
    // apart. A synthetic id (765611900...) is a hash of a name: players who joined by address
    // through the retired Sundial app have only that.
    internal static bool IsAccountId(string s) => s.Length == 32 && s.All(Uri.IsHexDigit);
    internal static bool IsSyntheticId(string s) =>
        s.Length > 9 && s.StartsWith("765611900", StringComparison.Ordinal) && s.All(char.IsDigit);

    // "<target> [rest]": the target is one word, or a quoted name ("Player 1").
    internal static (string Target, string Tail) SplitTarget(string arg)
    {
        var a = arg.Trim();
        if (a.StartsWith('"'))
        {
            var end = a.IndexOf('"', 1);
            if (end > 0) return (a[1..end].Trim(), a[(end + 1)..].Trim());
            return (a[1..].Trim(), "");
        }
        var parts = a.Split(' ', 2);
        return (parts[0].Trim(), parts.Length > 1 ? parts[1].Trim() : "");
    }

    // Resolve "name or id" to the id bans and kicks use. An id is used as given (works for
    // offline players). A name must match exactly one online player and resolves to that
    // player's roster id, which is the account id whenever the player has one: a name never
    // turns into a ban on everyone who shares it.
    internal static (string? Id, string? Error) ResolveUserId(string arg, IReadOnlyList<PlayerSnapshot> players)
    {
        var a = arg.Trim();
        if (a.Length == 0) return (null, "no player given");
        if (IsAccountId(a)) return (a.ToLowerInvariant(), null);
        if (IsSyntheticId(a)) return (a, null);
        var hits = players.Where(x => string.Equals(x.DisplayName, a, StringComparison.OrdinalIgnoreCase)).ToList();
        if (hits.Count == 0) return (null, $"no online player named '{a}'; use the id from players or bans");
        if (hits.Count > 1) return (null, $"{hits.Count} players are named '{a}'; use the id from players");
        var id = hits[0].SolarpunkUserId;
        if (string.IsNullOrEmpty(id)) return (null, $"'{a}' has no id yet; try again in a few seconds");
        return (IsAccountId(id) ? id.ToLowerInvariant() : id, null);
    }

    private string HandleBan(string rest)
    {
        var (who, reasonText) = SplitTarget(rest);
        var reason = reasonText.Length > 0 ? reasonText : "banned by admin";
        if (string.IsNullOrEmpty(who)) return "usage: ban <player|id> [reason]";
        var (id, err) = ResolveUserId(who, _state.Players);
        if (id is null) return $"ban: {err}";
        _saves.Database.AddBan(new BanRecord(id, reason, null, "rcon", NowUnix()));
        WriteBansFile();
        _log.LogInformation("RCON ban: id={Id} reason-len={Len}", id, reason.Length);
        return $"banned {who} ({id}): {reason}";
    }

    private string HandleUnban(string rest)
    {
        var id = rest.Trim();
        if (string.IsNullOrEmpty(id)) return "usage: unban <id> (the id from bans)";
        if (IsAccountId(id)) id = id.ToLowerInvariant();
        else if (!IsSyntheticId(id)) return "unban: give the id from bans (a player name is not an id)";
        _saves.Database.RemoveBan(id);
        WriteBansFile();
        _log.LogInformation("RCON unban: id={Id}", id);
        return $"unbanned {id}";
    }

    // RCON kick: the game side (SolarpunkAuth) finds the player by id, sends the kick message and
    // removes the player on the server if they are still connected 3 s later.
    private async Task<string> HandleKickAsync(string rest)
    {
        var (who, _) = SplitTarget(rest);
        if (string.IsNullOrEmpty(who)) return "usage: kick <player|id>";
        var (id, err) = ResolveUserId(who, _state.Players);
        if (id is null) return $"kick: {err}";
        var result = await KickRequestFile.AskAsync(AppContext.BaseDirectory, id, TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        _log.LogInformation("RCON kick: id={Id} result={Result}", id, result ?? "no answer");
        return result switch
        {
            null => "kick: no answer from the game in 5 s (is the server in its world?)",
            "kicked" => $"kicked {who} ({id})",
            "not-online" => $"kick: {who} ({id}) is not online",
            "already-leaving" => $"kick: {who} ({id}) is already leaving",
            _ => $"kick: {result}",
        };
    }

    private string HandleBans()
    {
        var bans = _saves.Database.ListActiveBans(NowUnix());
        if (bans.Count == 0) return "no active bans";
        var sb = new StringBuilder($"{bans.Count} active ban(s):\n");
        foreach (var b in bans)
            sb.AppendLine($"  {b.SolarpunkUserId}  {(b.ExpiresUnix is null ? "perm" : "temp")}  {b.Reason}");
        return sb.ToString().TrimEnd();
    }

    // Publish active banned ids (one synth id per line) to bans.txt next to
    // SolarpunkServer.exe; the in-game gate (SolarpunkAuth Lua) reads it and
    // kicks matching players at join + on its sweep. Atomic temp+rename.
    private void WriteBansFile()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "bans.txt");
            var ids = _saves.Database.ListActiveBans(NowUnix()).Select(b => b.SolarpunkUserId);
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, string.Join("\n", ids) + "\n");
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception ex) { _log.LogWarning(ex, "failed to write bans.txt"); }
    }

    private string HandleChat(string msg, string channel)
    {
        var clean = (msg ?? "").Trim();
        if (string.IsNullOrEmpty(clean)) return $"usage: {(channel == "admin" ? "announce" : "say")} <message>";
        var entry = _chat.BroadcastFromServer(clean, channel: channel, sender: "Server");
        return $"chat ok ({channel}): {entry.Msg}";
    }

    private string HandleMotd(string sub)
    {
        var trimmed = (sub ?? "").Trim();
        if (string.IsNullOrEmpty(trimmed))
        {
            var cur = _chat.GetMotd();
            return string.IsNullOrEmpty(cur) ? "motd is empty" : $"motd: {cur}";
        }
        return _chat.SetMotd(trimmed) ? "motd updated" : "motd update failed (check log)";
    }

    private async Task<string> HandleSaveAsync(string sub)
    {
        var arg = sub.Trim().ToLowerInvariant();
        if (string.IsNullOrEmpty(arg) || arg == "snapshot")
        {
            // The game host auto-saves to <userdir>/Saved/SaveGames every ~60s.
            // We snapshot the on-disk save file directly; the plugin SaveQuiesce
            // ack is not required because the game's own save writer is atomic
            // (writes to temp then renames). The FileSystemWatcher in
            // SaveOrchestratorService handles auto-snapshots; this RCON path is
            // for admin-triggered.
            var rec = await _saves.SnapshotAsync("rcon").ConfigureAwait(false);
            return rec is null
                ? "snapshot failed (check solarpunk log; save dir likely missing)"
                : $"snapshot ok: {rec.SnapshotId} ({rec.SizeBytes} bytes, sha={rec.Sha256Hex[..16]})";
        }
        if (arg == "list")
        {
            var snaps = _saves.Database.ListSnapshots(20);
            if (snaps.Count == 0) return "no snapshots yet";
            var sb = new System.Text.StringBuilder();
            foreach (var s in snaps)
                sb.AppendLine($"{s.SnapshotId}  {s.SizeBytes}B  age={(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - s.TakenUnix)}s  sha={s.Sha256Hex[..16]}");
            return sb.ToString().TrimEnd();
        }
        return "usage: save snapshot | save list";
    }

    private string BuildStatus()
    {
        var conn = _state.Connection;
        return conn is null
            ? $"instance={_opts.InstanceId} plugin=disconnected players={_state.EffectivePlayerCount}"
            : $"instance={_opts.InstanceId} plugin=connected pid={conn.PluginPid} version={conn.PluginVersion} players={_state.EffectivePlayerCount}";
    }

    private string BuildPlayers() => FormatPlayers(_state.Players, _state.EffectivePlayerCount);

    // One line per player: name and id (the account id for invite-code players), so an admin can
    // kick or ban the right one when names repeat.
    internal static string FormatPlayers(IReadOnlyList<PlayerSnapshot> players, int count)
    {
        if (players.Count == 0)
            return count == 0 ? "no players online" : $"{count} player(s) online (names not available yet)";
        var sb = new StringBuilder($"{players.Count} player(s) online:");
        foreach (var p in players.OrderBy(x => x.DisplayName, StringComparer.OrdinalIgnoreCase))
            sb.Append('\n').Append("  ").Append(p.DisplayName).Append("  ").Append(p.SolarpunkUserId);
        return sb.ToString();
    }
}
