namespace SolarpunkServer.Configuration;

public sealed class SolarpunkServerOptions
{
    /// <summary>
    /// When true, the process logs at Debug level (per-request HTTP, A2S query
    /// decisions, RCON auth/dispatch, heartbeat transitions, pidfile probes).
    /// Default false = Information. Can also be enabled via the SOLARPUNK_VERBOSE
    /// env var. Read at startup in Program.ResolveVerbose to set Serilog's
    /// minimum level; this field documents/binds the appsettings.json key.
    /// </summary>
    public bool Verbose { get; set; }

    public string InstanceId { get; set; } = "default";

    public string PipeName { get; set; } = @"Solarpunk\default";

    /// <summary>Path to a 64-hex-character HMAC key file, generated per instance.</summary>
    public string HmacKeyPath { get; set; } = "data/hmac.key";

    public int GameplayPort { get; set; } = 27015;

    public int ControlPort { get; set; } = 27016;

    public int QueryPort { get; set; } = 27017;

    public int RconPort { get; set; } = 27018;

    /// <summary>
    /// HTTP API port. Used by the launcher to list/upload/download/restore
    /// snapshots and to fetch instance metadata. Auth is per-instance HMAC,
    /// same key as the named-pipe IPC.
    /// </summary>
    public int HttpPort { get; set; } = 27019;

    /// <summary>
    /// Maximum upload size for snapshot import / restore. Solarpunk worlds
    /// are typically &lt; 200 MB; cap at 2 GB by default to reject malformed
    /// or hostile uploads without exhausting RAM.
    /// </summary>
    public long MaxUploadBytes { get; set; } = 2L * 1024 * 1024 * 1024;

    public string RconPassword { get; set; } = "";

    /// <summary>
    /// LEGACY/RESERVED field — IGNORED. Native password enforcement is
    /// intentionally OFF for Solarpunk: the native SolarpunkPlugin.dll handles
    /// net-id minting only, and the G2/Lantern precedent (native gate racing
    /// the game's internal map travel and fatal-crashing the host) is the
    /// reason no native gate is wired here either. Password enforcement
    /// routes through the SolarpunkAuth Lua gate only (see
    /// <see cref="SolarpunkAuthPassword"/>). Field is kept for appsettings.json
    /// schema parity with Beacon/Lantern; do NOT set it.
    /// </summary>
    public string ServerPassword { get; set; } = "";

    /// <summary>
    /// Password enforced by SolarpunkAuth.lua's K2_PostLogin hook for
    /// incoming remote clients. Written by the panel into appsettings.json.
    /// Empty string means open server (no password gate). The listen-server
    /// host is positively detected and exempt from the gate. Used by
    /// SourceQueryHostedService for the A2S PasswordRequired flag so the
    /// Steam server browser correctly advertises passworded instances.
    /// </summary>
    public string SolarpunkAuthPassword { get; set; } = "";

    public string ServerName { get; set; } = "";

    public string GameInstallRoot { get; set; } = @"C:\Solarpunk\game";

    /// <summary>
    /// Optional direct path to the Solarpunk executable
    /// (SolarpunkSteam-Win64-Shipping.exe). Leave empty to auto-detect the
    /// supported Steam Win64 layouts under <see cref="GameInstallRoot"/>.
    /// </summary>
    public string GameExecutablePath { get; set; } = "";

    public string GameUserDir { get; set; } = @"C:\Solarpunk\userdir";

    public string SaveDir { get; set; } = @"C:\Solarpunk\saves";

    /// <summary>
    /// Optional path to a single-line file containing the PID of the game
    /// process this SolarpunkServer instance owns. Used by KillGame as a
    /// fallback when neither <see cref="GameInstallRoot"/> nor a command-line
    /// scope exists (e.g. panel-managed deploys where the panel's
    /// PowerShell owns the game's lifecycle and writes Logs\game.pid). The pid
    /// is always validated against the game process-name whitelist before
    /// kill — a recycled OS PID owned by an unrelated process will not
    /// be touched. Empty disables the pid-file kill path.
    /// </summary>
    public string GamePidFile { get; set; } = "";

    /// <summary>Heartbeat window — if plugin doesn't ping in this many seconds, assume crashed.</summary>
    public int PluginHeartbeatTimeoutSeconds { get; set; } = 30;

    /// <summary>
    /// Slot count reported via A2S. The session UI labels lobbies as 1/4, so
    /// 4 is the natural default — anything higher and the in-game host UI
    /// reports a slot count that doesn't match what SolarpunkServer hands out.
    /// </summary>
    public int MaxPlayers { get; set; } = 4;

    /// <summary>
    /// Take a snapshot zip of the SaveGames dir into <see cref="SaveDir"/>
    /// on every auto-save (via FileSystemWatcher). Useful for self-hosters
    /// who want a rollback option. Hosting providers
    /// run their own backup chain and should set this to false to avoid
    /// disk churn — a 1-per-minute snapshot rate produces ~1500 zips and
    /// ~1 GB per gameserver per day.
    /// </summary>
    public bool SnapshotsEnabled { get; set; } = true;

    /// <summary>Chat plane configuration. See protocol/chat-v1.md.</summary>
    public ChatOptions Chat { get; set; } = new();

    /// <summary>
    /// Mod manifest published at GET /api/v1/manifest. Hosters list the mods
    /// they require, recommend, or forbid; the launcher reads this on join
    /// and installs/offers/warns accordingly. Spec: protocol/manifest-v1.md.
    /// </summary>
    public ModsOptions Mods { get; set; } = new();

    /// <summary>Live web map. See protocol/map-v1.md.</summary>
    public MapOptions Map { get; set; } = new();
}

public sealed class ChatOptions
{
    /// <summary>In-memory ring buffer cap for /api/v1/chat/recent. Min 20, default 200.</summary>
    public int RingBufferSize { get; set; } = 200;
}

public sealed class ModsOptions
{
    public List<ModEntry> Required { get; set; } = new();
    public List<ModEntry> Recommended { get; set; } = new();
    public List<BlockedModEntry> Blocked { get; set; } = new();
}

public sealed class ModEntry
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Version { get; set; } = "";
    public string Url { get; set; } = "";
    public string? Sha256 { get; set; }
    public long? SizeBytes { get; set; }
    public string InstallRoot { get; set; } = "";
    public string? Notes { get; set; }
}

public sealed class BlockedModEntry
{
    public string Id { get; set; } = "";
    public string Reason { get; set; } = "";
}

public sealed class MapOptions
{
    /// <summary>Master toggle. When false, /api/v1/map/state returns 404.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// When true, /api/v1/map/state and the /map/ SPA are reachable without
    /// HMAC auth. Use for community-facing servers that want to publish a
    /// live map dashboard. Default false — server admin/launcher only.
    /// </summary>
    public bool Public { get; set; } = false;

    /// <summary>
    /// Cap on cached state age (ms). If roster.json is older than this,
    /// /api/v1/map/state still serves it but flags stale=true so the SPA
    /// can dim or warn. Default 10000 (10s).
    /// </summary>
    public int StaleAfterMs { get; set; } = 10000;
}
