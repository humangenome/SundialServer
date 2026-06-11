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
            "help"     => "commands: status, players, ping, save snapshot, save list, say <msg>, announce <msg>, motd [msg], ban <player|id> [reason], unban <id>, bans",
            "status"   => BuildStatus(),
            "players"  => BuildPlayers(),
            "ping"     => "pong",
            "save"     => await HandleSaveAsync(rest).ConfigureAwait(false),
            "snapshot" => await HandleSaveAsync("snapshot").ConfigureAwait(false),
            "say"      => HandleChat(rest, "system"),
            "announce" => HandleChat(rest, "admin"),
            "motd"     => HandleMotd(rest),
            "ban"      => HandleBan(rest),
            "unban"    => HandleUnban(rest),
            "bans"     => HandleBans(),
            _          => $"unknown rcon command: {head} (try: help)",
        };
    }

    private static long NowUnix() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    // Resolve a "name or id" argument to a synthetic SolarpunkUserId. A bare
    // synth id (765611900…) is used directly (works for offline players);
    // otherwise match an online player's DisplayName case-insensitively.
    private string? ResolveUserId(string arg)
    {
        var a = arg.Trim();
        if (a.StartsWith("765611900", StringComparison.Ordinal) && a.All(char.IsDigit)) return a;
        var p = _state.Players.FirstOrDefault(x =>
            string.Equals(x.DisplayName, a, StringComparison.OrdinalIgnoreCase));
        return p?.SolarpunkUserId;
    }

    private string HandleBan(string rest)
    {
        var parts = rest.Split(' ', 2);
        var who = parts.Length > 0 ? parts[0].Trim() : "";
        var reason = parts.Length > 1 ? parts[1].Trim() : "banned by admin";
        if (string.IsNullOrEmpty(who)) return "usage: ban <playername|id> [reason]";
        var id = ResolveUserId(who);
        if (string.IsNullOrEmpty(id))
            return $"ban: no online player named '{who}' — ban by synthetic id (765611900…) if offline";
        _saves.Database.AddBan(new BanRecord(id, reason, null, "rcon", NowUnix()));
        WriteBansFile();
        _log.LogInformation("RCON ban: id={Id} reason-len={Len}", id, reason.Length);
        return $"banned {who} ({id}): {reason}";
    }

    private string HandleUnban(string rest)
    {
        var id = rest.Trim();
        if (string.IsNullOrEmpty(id)) return "usage: unban <id 765611900…>";
        _saves.Database.RemoveBan(id);
        WriteBansFile();
        _log.LogInformation("RCON unban: id={Id}", id);
        return $"unbanned {id}";
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
            ? $"instance={_opts.InstanceId} plugin=disconnected"
            : $"instance={_opts.InstanceId} plugin=connected pid={conn.PluginPid} version={conn.PluginVersion} players={_state.EffectivePlayerCount}";
    }

    private string BuildPlayers()
    {
        var n = _state.EffectivePlayerCount;
        return n == 0 ? "no players online" : $"{n} player(s) online (per-player names land in Phase 2)";
    }
}
