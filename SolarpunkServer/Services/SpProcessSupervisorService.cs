using System.Diagnostics;
using System.Text.Json;
using SolarpunkServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace SolarpunkServer.Services;

/// <summary>
/// Launches the Solarpunk headless host (Steam app 1805110,
/// <c>SolarpunkSteam-Win64-Shipping.exe -nullrhi</c>), patches the user-scope
/// Engine.ini for the OSS=Null + IpNetDriver transport override on every
/// launch, watches the process, restarts on unexpected exit.
///
/// Hosting model: Solarpunk has no <c>?listen</c> travel URL. The game boots
/// to its menu; the server-side UE4SS mod (host_netid_enforcer.lua) swaps the
/// NetDriver to IpNetDriver and calls <c>BP_SkyGameInstance:HostGame()</c>,
/// which loads /Game/Maps/MainLevel and binds the UDP gameplay port from
/// Engine.ini [URL] Port. The supervisor therefore launches the bare exe and
/// owns only the process lifecycle + transport config — no map/save-slot
/// launch arguments.
///
/// Crash policy: if the game exits within MinHealthyUptimeSeconds, treat as
/// "boot loop" and back off exponentially. After a stable run, exit codes
/// reset the backoff.
///
/// In a hosting-provider managed deploy an external script can own the
/// game lifecycle, so GameInstallRoot/GameExecutablePath are left EMPTY and
/// this supervisor stays idle (it returns immediately from ExecuteAsync) —
/// the SnInstallRoot="" model from Beacon.
/// </summary>
public sealed class SpProcessSupervisorService : BackgroundService
{
    private readonly ILogger<SpProcessSupervisorService> _log;
    private readonly SolarpunkServerOptions _opts;
    private readonly HmacKeyService _hmac;
    private readonly SpRestartCoordinator _coordinator;

    private const int MinHealthyUptimeSeconds = 60;
    private const int MaxBackoffSeconds = 300;
    private static readonly string[][] SpExeRelativePaths =
    [
        ["Solarpunk", "Binaries", "Win64", "SolarpunkSteam-Win64-Shipping.exe"],
        ["Binaries", "Win64", "SolarpunkSteam-Win64-Shipping.exe"],
        ["Solarpunk", "Binaries", "Win64", "Solarpunk-Win64-Shipping.exe"],
        ["Binaries", "Win64", "Solarpunk-Win64-Shipping.exe"],
        ["SolarpunkSteam-Win64-Shipping.exe"],
        ["Solarpunk-Win64-Shipping.exe"],
    ];
    public SpProcessSupervisorService(
        ILogger<SpProcessSupervisorService> log,
        IOptions<SolarpunkServerOptions> opts,
        HmacKeyService hmac,
        SpRestartCoordinator coordinator)
    {
        _log = log;
        _opts = opts.Value;
        _hmac = hmac;
        _coordinator = coordinator;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if ((string.IsNullOrEmpty(_opts.GameInstallRoot) && string.IsNullOrEmpty(_opts.GameExecutablePath))
            || !OperatingSystem.IsWindows())
        {
            _log.LogWarning("Process supervisor idle: Solarpunk executable not configured or not on Windows");
            return;
        }

        var backoffSeconds = 1;
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                // Wait for any in-flight restore to finish before relaunching.
                // The restore code holds the gate while it mutates SaveGames;
                // launching Solarpunk while that's in progress would race the file
                // copy and corrupt the world.
                await _coordinator.WaitForNoRestoreAsync(stoppingToken).ConfigureAwait(false);

                ApplyEngineIniPatch();
                EmitPluginConfig();
                var start = DateTime.UtcNow;

                using var proc = LaunchGame();
                _log.LogInformation("Solarpunk launched: pid={Pid}", proc.Id);
                while (!stoppingToken.IsCancellationRequested && !proc.HasExited)
                {
                    await Task.Delay(TimeSpan.FromSeconds(1), stoppingToken).ConfigureAwait(false);
                }
                if (stoppingToken.IsCancellationRequested)
                {
                    if (!proc.HasExited)
                    {
                        _log.LogInformation("Stopping — sending Ctrl+C / Close to Solarpunk (pid={Pid})", proc.Id);
                        try { proc.CloseMainWindow(); } catch { }
                        if (!proc.WaitForExit(10_000)) proc.Kill(true);
                    }
                    return;
                }

                var uptime = DateTime.UtcNow - start;
                _log.LogWarning("Solarpunk exited code={Code} uptime={Uptime}s", proc.ExitCode, (int)uptime.TotalSeconds);

                if (uptime.TotalSeconds >= MinHealthyUptimeSeconds)
                {
                    backoffSeconds = 1; // stable run — reset backoff
                }
                else
                {
                    backoffSeconds = Math.Min(MaxBackoffSeconds, backoffSeconds * 2);
                    _log.LogWarning("Boot-loop suspected — backing off {Seconds}s before restart", backoffSeconds);
                    try { await Task.Delay(TimeSpan.FromSeconds(backoffSeconds), stoppingToken).ConfigureAwait(false); }
                    catch (OperationCanceledException) { return; }
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                _log.LogError(ex, "Supervisor loop error — retry in 5s");
                try { await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    private Process LaunchGame()
    {
        var exe = ResolveSpExecutablePath(_opts);
        if (!File.Exists(exe))
            throw new FileNotFoundException($"Solarpunk binary not found at {exe}");

        // -nullrhi: no rendering — the proven headless render mode for this
        //   build (UE 5.7). Don't use -RenderOffscreen/-WARP unless density
        //   testing says otherwise.
        // -UserDir: stock UE5 FPaths::ProjectUserDir override; isolates this
        //   instance's Saved/ (config, logs, SaveGames) from any other install.
        // The map + hosting come from host_netid_enforcer.lua (HostGame()),
        // not from launch arguments. The UDP gameplay port comes from the
        // Engine.ini [URL] Port written by ApplyEngineIniPatch.
        var args = string.Join(' ',
            $"-UserDir={EscapeArg(_opts.GameUserDir)}",
            "-nullrhi",
            "-unattended",
            $"-port={_opts.GameplayPort}",
            "-log");

        var psi = new ProcessStartInfo
        {
            FileName = exe,
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = false,
            WorkingDirectory = Path.GetDirectoryName(exe)!,
        };
        psi.EnvironmentVariables["SOLARPUNK_INSTANCE"] = _opts.InstanceId;
        return Process.Start(psi) ?? throw new InvalidOperationException("Process.Start returned null");
    }

    private void ApplyEngineIniPatch()
    {
        // Refuse to patch into a user directory that overlaps a vanilla
        // Solarpunk install. This catches the case where GameUserDir was
        // accidentally pointed at the customer's Steam Solarpunk root and
        // would otherwise overwrite their vanilla Engine.ini.
        if (LooksLikeVanillaInstallPath(_opts.GameUserDir))
        {
            _log.LogError("Engine.ini patch refused: GameUserDir={Dir} looks like a vanilla Solarpunk install path. " +
                          "Solarpunk's user dir must be a separate folder (e.g. C:\\SolarpunkHost\\UserDir).",
                          _opts.GameUserDir);
            return;
        }

        var configDir = Path.Combine(_opts.GameUserDir, "Saved", "Config", "Windows");
        Directory.CreateDirectory(configDir);
        var enginePath = Path.Combine(configDir, "Engine.ini");

        // Mirrors the proven transport keystone (solarpunk/launcher/
        // Engine.ini.client): [OnlineSubsystemSteam] bEnabled=false is the
        // load-bearing line — it deregisters SteamSockets so the stock
        // UIpNetDriver binds a real UDP socket instead of a SteamID. The
        // headless host box usually has no Steam client running (so this is
        // already implicit), but writing it makes the bind deterministic.
        // The host_netid_enforcer.lua mod additionally swaps the live
        // NetDriverDefinitions at runtime; the Engine.ini override makes the
        // swap a no-op on boots where the config is honored first.
        const string driver = "/Script/OnlineSubsystemUtils.IpNetDriver";
        var content = $"""
        ; Solarpunk-managed Engine.ini override — rewritten on every host launch.
        [OnlineSubsystem]
        DefaultPlatformService=Null

        [OnlineSubsystemSteam]
        bEnabled=false

        [OnlineSubsystemNull]
        bSimulateForwarded=true

        [/Script/Engine.GameEngine]
        !NetDriverDefinitions=ClearArray
        +NetDriverDefinitions=(DefName="GameNetDriver",DriverClassName="{driver}",DriverClassNameFallback="{driver}")

        [/Script/Engine.Engine]
        !NetDriverDefinitions=ClearArray
        +NetDriverDefinitions=(DefName="GameNetDriver",DriverClassName="{driver}",DriverClassNameFallback="{driver}")

        [/Script/OnlineSubsystemUtils.IpNetDriver]
        NetConnectionClassName=/Script/OnlineSubsystemUtils.IpConnection
        AllowPeerConnections=false
        AllowPeerVoice=false
        bClampListenServerTickRate=true
        NetServerMaxTickRate=60
        MaxClientRate=2097152
        MaxInternetClientRate=2097152
        NetConnectionTimeout=60
        InitialConnectTimeout=300.0
        ConnectionTimeout=300.0
        ServerTravelPause=4

        [/Script/Engine.GameNetworkManager]
        TotalNetBandwidth=16777216
        MaxDynamicBandwidth=2097152
        MinDynamicBandwidth=524288

        [URL]
        Port={_opts.GameplayPort}
        """;
        File.WriteAllText(enginePath, content);
        _log.LogInformation("Patched Engine.ini at {Path}", enginePath);
    }

    private void EmitPluginConfig()
    {
        var exe = ResolveSpExecutablePath(_opts);
        var pluginDir = Path.Combine(Path.GetDirectoryName(exe)!,
            "Mods", "Solarpunk");
        Directory.CreateDirectory(pluginDir);
        var configPath = Path.Combine(pluginDir, "solarpunk.config.json");

        // ServerPassword is INTENTIONALLY emitted empty. Password
        // enforcement (when shipped) lives in the SolarpunkAuth Lua gate's
        // K2_PostLogin hook, which gates remote clients only and exempts the
        // listen host. The native SolarpunkPlugin.dll handles net-id minting
        // only and never enforces a password (the G2 native gate fatal-crash
        // race is the precedent for keeping native enforcement off).
        var payload = new
        {
            InstanceId = _opts.InstanceId,
            PipePath = $@"\\.\pipe\{_opts.PipeName}",
            HmacKeyHex = Convert.ToHexString(_hmac.Key),
            ServerPassword = "",
        };
        File.WriteAllText(configPath, JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true }));
        _log.LogInformation("Emitted plugin config at {Path}", configPath);
    }

    private static string EscapeArg(string s) => s.Contains(' ') ? $"\"{s}\"" : s;

    internal static string ResolveSpExecutablePath(SolarpunkServerOptions opts)
    {
        if (!string.IsNullOrWhiteSpace(opts.GameExecutablePath))
        {
            return Path.GetFullPath(opts.GameExecutablePath);
        }

        foreach (var relativePath in SpExeRelativePaths)
        {
            var candidate = Path.Combine([opts.GameInstallRoot, .. relativePath]);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return Path.Combine([opts.GameInstallRoot, .. SpExeRelativePaths[0]]);
    }

    /// <summary>
    /// Heuristic: does this path look like a Steam / Epic / MS Store install
    /// root for vanilla Solarpunk? Used to refuse Engine.ini / plugin-config
    /// writes that would corrupt a vanilla install if GameUserDir/GameInstallRoot
    /// were misconfigured.
    /// </summary>
    internal static bool LooksLikeVanillaInstallPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        // Check the resolved real target too — a customer can junction
        // their Solarpunk user dir at C:\Solarpunk\userdir over a vanilla
        // install and the literal-string check passes while the
        // Engine.ini write lands inside the vanilla folder.
        return MatchesVanillaSubstring(path)
            || MatchesVanillaSubstring(TryResolveSymlinkTarget(path));
    }

    private static bool MatchesVanillaSubstring(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        var p = path.Replace('/', '\\').ToLowerInvariant();
        return p.Contains(@"\steamapps\common\")
            || p.Contains(@"\steamlibrary\")
            || p.Contains(@"\epicgameslauncher\")
            || p.Contains(@"\epic games\")
            || p.Contains(@"\windowsapps\");
    }

    private static string? TryResolveSymlinkTarget(string path)
    {
        try
        {
            // DirectoryInfo.LinkTarget on .NET 6+ returns the immediate
            // target of a junction/symlink; null otherwise. Path.GetFullPath
            // canonicalises any '..' segments. ResolveLinkTarget(true)
            // walks the chain (multiple junctions) but isn't strictly
            // needed for the common case.
            var di = new DirectoryInfo(path);
            if (!di.Exists) return null;
            var resolved = di.ResolveLinkTarget(true);
            return resolved?.FullName;
        }
        catch { return null; }
    }
}
