using System.Diagnostics;
using SolarpunkServer.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace SolarpunkServer.Services;

/// <summary>
/// Watches plugin heartbeats. If we haven't heard from the plugin in
/// <see cref="SolarpunkServerOptions.PluginHeartbeatTimeoutSeconds"/>, log a warning;
/// future work hooks process supervision into this to restart the Solarpunk instance.
///
/// Password enforcement model:
///   Password enforcement lives in SolarpunkAuth.lua's K2_PostLogin hook on
///   incoming remote clients. The native SolarpunkPlugin.dll ApproveLogin hook is
///   INTENTIONALLY disabled (see SpProcessSupervisorService.EmitPluginConfig
///   for the Solarpunk crash-loop rationale). EmitPluginConfig always emits an
///   empty ServerPassword to plugin-config.json, so the native gate has
///   nothing to enforce.
///
///   The legacy <see cref="CheckServerPasswordReady"/> path is kept as a
///   defensive bug-detector: if the plugin EVER reports
///   ServerPasswordConfigured=1, something has gone wrong upstream (a
///   stale plugin-config.json carrying a non-empty ServerPassword from an
///   earlier deploy, or a manually-edited plugin config). In that
///   case the native and Lua paths could race and reproduce the Solarpunk
///   crash loop, so we kill the game loudly with a CRITICAL log rather than
///   let a customer hit it. The expected steady-state is
///   Configured=0 + HookReady=0 across the entire fleet.
/// </summary>
public sealed class HeartbeatWatchdogService : BackgroundService
{
    private readonly ILogger<HeartbeatWatchdogService> _log;
    private readonly PipeServerState _state;
    private readonly SpRestartCoordinator _coordinator;
    private readonly SolarpunkServerOptions _opts;
    private readonly TimeSpan _timeout;

    // Grace period after we first see the plugin connect before we'll
    // start fail-closing. The plugin's bootstrap thread installs the
    // ApproveLogin hook AFTER the pipe handshake, so the first few
    // heartbeats can legitimately report hook-not-ready while the
    // bootstrap is still racing.
    private static readonly TimeSpan AuthGraceWindow = TimeSpan.FromSeconds(20);

    // Throttle for the "configured but native gate down" warning so we
    // don't spam the log every ~10s while waiting on the supervisor.
    private DateTimeOffset _lastFailClosedWarnAt = DateTimeOffset.MinValue;

    public HeartbeatWatchdogService(
        ILogger<HeartbeatWatchdogService> log,
        PipeServerState state,
        SpRestartCoordinator coordinator,
        IOptions<SolarpunkServerOptions> options)
    {
        _log = log;
        _state = state;
        _coordinator = coordinator;
        _opts = options.Value;
        _timeout = TimeSpan.FromSeconds(options.Value.PluginHeartbeatTimeoutSeconds);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var period = TimeSpan.FromSeconds(Math.Max(1, _timeout.TotalSeconds / 3));
        using var timer = new PeriodicTimer(period);
        while (await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false))
        {
            try
            {
                CheckHeartbeatStale();
                CheckServerPasswordReady();
                CheckSolarpunkAuthLuaReady();
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "HeartbeatWatchdog tick error");
            }
        }
    }

    private static readonly TimeSpan LuaStatusBootstrapGrace = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan LuaStatusFreshWindow = TimeSpan.FromSeconds(90);
    // Wider grace for the no-connection-at-all case: covers the cold-start
    // window where the game process is launching and the Lua runtime has not
    // published a current auth-ready status yet. The native pipe is optional on
    // the panel-managed Solarpunk path; Lua status is the authoritative gate.
    private static readonly TimeSpan NoConnectionFailClosedGrace = TimeSpan.FromSeconds(180);
    private DateTimeOffset _lastLuaFailClosedWarnAt = DateTimeOffset.MinValue;
    private readonly DateTimeOffset _serverStartedAt = DateTimeOffset.UtcNow;

    // The "no-connection-window-started-at" anchor. Reset whenever we observe
    // a live connection. Without this reset, a long-lived SolarpunkServer that
    // briefly loses its pipe (e.g. game process crash + relaunch driven by
    // SolarpunkServer's own supervisor, or by the panel's PowerShell) would
    // skip the cold-start grace on the relaunch and fail-closed immediately
    // even though the new game process needs its own 30-60s cold launch.
    // Initialized to _serverStartedAt so the very first game launch gets the
    // full grace window from SolarpunkServer process startup.
    private DateTimeOffset _noConnSince = DateTimeOffset.UtcNow;

    private void CheckSolarpunkAuthLuaReady()
    {
        // Fail-closed for the Lua-only password-enforcement model.
        // If SolarpunkAuthPassword is configured but the Lua gate isn't
        // reporting ready, kill the game to prevent the server from
        // running open without a gate. SolarpunkAuth.lua writes
        // SolarpunkServer/.solarpunk-auth-status with key=value pairs:
        //   ready=0|1
        //   passwordConfigured=0|1
        //   updated=<unix>
        //   reason=<short string>
        //
        // Fail-closed paths:
        //   1. No pipe connection at all (UE4SS never loaded, SolarpunkLoader
        //      failed, SolarpunkPlugin.dll never connected) past NoConnectionFailClosedGrace
        //      since SolarpunkServer process start. Use path-scoped KillGame
        //      (only effective on standalone — panel deploys log loudly).
        //   2. Pipe connection exists but SolarpunkAuth status is not ready
        //      past LuaStatusBootstrapGrace since handshake. Use BOTH
        //      path-scoped KillGame AND PluginPid-based kill.
        if (string.IsNullOrEmpty(_opts.SolarpunkAuthPassword)) return;

        string statusPath;
        try
        {
            var baseDir = AppContext.BaseDirectory;
            statusPath = Path.Combine(baseDir, ".solarpunk-auth-status");
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "SolarpunkAuth status path resolve failed");
            return;
        }

        var status = ReadLuaStatus(statusPath);
        var luaGateReady = status.exists
            && status.passwordConfigured
            && status.ready
            && IsLuaStatusFresh(status.updatedAt, LuaStatusFreshWindow);

        var conn = _state.Connection;
        if (conn is not null)
        {
            // Live connection observed. Reset the no-connection anchor so
            // that any FUTURE drop gets a fresh 180s grace window. This is
            // the fix for the case where the anchor was the DI construction
            // time, which meant a long-running SolarpunkServer would skip grace
            // on a later game restart and immediately fail-closed during the
            // new game's legitimate cold-launch window.
            _noConnSince = DateTimeOffset.UtcNow;
        }
        if (conn is null)
        {
            if (luaGateReady) return;

            // Grace window since we last had a connection (or since
            // SolarpunkServer process startup if we've never had one).
            var sinceConnLost = DateTimeOffset.UtcNow - _noConnSince;
            if (sinceConnLost < NoConnectionFailClosedGrace) return;

            var noConnNow = DateTimeOffset.UtcNow;
            var noConnSinceWarn = noConnNow - _lastLuaFailClosedWarnAt;
            if (noConnSinceWarn > TimeSpan.FromSeconds(15))
            {
                _log.LogCritical(
                    "FAIL-CLOSED: SolarpunkAuthPassword is configured but SolarpunkAuth.lua is not publishing a fresh ready status " +
                    "past {Grace}s grace (exists={Exists} ready={Ready} passwordConfigured={PwConfigured} reason='{Reason}' updated={Updated} path={Path}). " +
                    "Stopping Solarpunk to prevent the passworded server from running open without the Lua password gate. " +
                    "Diagnose: check UE4SS.log for SolarpunkServerRuntime/SolarpunkAuth load failures.",
                    NoConnectionFailClosedGrace.TotalSeconds,
                    status.exists,
                    status.ready,
                    status.passwordConfigured,
                    status.reason,
                    status.updatedAt?.ToUnixTimeSeconds(),
                    statusPath);
                _lastLuaFailClosedWarnAt = noConnNow;
            }
            try
            {
                _coordinator.KillGame(TimeSpan.FromSeconds(10));
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "FAIL-CLOSED (no-conn): KillGame threw");
            }
            return;
        }
        var sinceConnect = DateTimeOffset.UtcNow - conn.ConnectedAt;
        if (sinceConnect < LuaStatusBootstrapGrace) return;

        // Stale-file protection: SolarpunkServerRuntime/main.lua atomically
        // overwrites .solarpunk-auth-status with ready=0,reason=runtime_init
        // BEFORE SolarpunkAuth runs, on every game process start (see the
        // write_not_ready_at pass at the top of that script). If runtime
        // can't overwrite (file lock + all retries fail), it calls
        // error(...) to abort SolarpunkServerRuntime entirely — SolarpunkLoader
        // and SolarpunkAuth never load, SolarpunkPlugin.dll never injects, no pipe
        // handshake happens, and the no-connection fail-closed path in
        // CheckSolarpunkAuthLuaReady (above) takes the game down via pid-file.
        // So any .solarpunk-auth-status the watchdog reads here with
        // ready=1 + passwordConfigured=1 with a fresh updated timestamp was
        // written by this game process's SolarpunkAuth.lua heartbeat.
        if (luaGateReady) return;

        var now = DateTimeOffset.UtcNow;
        var sinceWarn = now - _lastLuaFailClosedWarnAt;
        if (sinceWarn > TimeSpan.FromSeconds(15))
        {
            _log.LogCritical(
                "FAIL-CLOSED: SolarpunkAuthPassword is configured but SolarpunkAuth.lua status is not ready " +
                "(exists={Exists} ready={Ready} passwordConfigured={PwConfigured} reason='{Reason}' updated={Updated} path={Path}). " +
                "Stopping Solarpunk to prevent the passworded server from running open without the Lua password gate. " +
                "Investigate UE4SS load failure / SolarpunkAuth.lua install / mods.txt ordering; the supervisor will " +
                "relaunch the game on the next loop.",
                status.exists, status.ready, status.passwordConfigured, status.reason, status.updatedAt?.ToUnixTimeSeconds(), statusPath);
            _lastLuaFailClosedWarnAt = now;
        }

        try
        {
            // Path-scoped KillGame is best-effort on panel-managed deploys
            // (GameInstallRoot is empty), so also try the PID-based kill
            // path via the active pipe connection. PluginPid is the game
            // process that loaded SolarpunkPlugin.dll (SolarpunkPlugin.dll calls
            // GetCurrentProcessId in its handshake), so if we have an
            // active pipe handshake, we know the exact PID to kill.
            _coordinator.KillGame(TimeSpan.FromSeconds(10));
            TryKillByPluginPid(conn.PluginPid);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "FAIL-CLOSED (Lua): KillGame / KillByPluginPid threw");
        }
    }

    private (bool ready, bool passwordConfigured, string reason, bool exists, DateTimeOffset? updatedAt) ReadLuaStatus(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return (false, false, "file_missing", false, null);
            }
            var lines = File.ReadAllLines(path);
            bool ready = false;
            bool passwordConfigured = false;
            string reason = "";
            DateTimeOffset? updatedAt = null;
            foreach (var line in lines)
            {
                var eq = line.IndexOf('=');
                if (eq <= 0) continue;
                var key = line.Substring(0, eq).Trim();
                var value = line.Substring(eq + 1).Trim();
                switch (key)
                {
                    case "ready": ready = value == "1"; break;
                    case "passwordConfigured": passwordConfigured = value == "1"; break;
                    case "reason": reason = value; break;
                    case "updated":
                        if (long.TryParse(value, out var unixSeconds))
                        {
                            try { updatedAt = DateTimeOffset.FromUnixTimeSeconds(unixSeconds); }
                            catch { updatedAt = null; }
                        }
                        break;
                }
            }
            return (ready, passwordConfigured, reason, true, updatedAt);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "SolarpunkAuth status read failed: {Path}", path);
            return (false, false, "read_error", false, null);
        }
    }

    private static bool IsLuaStatusFresh(DateTimeOffset? updatedAt, TimeSpan maxAge)
    {
        if (updatedAt is null) return false;
        var age = DateTimeOffset.UtcNow - updatedAt.Value;
        return age >= TimeSpan.Zero && age <= maxAge;
    }

    private static readonly string[] SpKillProcessNameWhitelist = new[]
    {
        // Process names are sometimes case-insensitive on Windows;
        // Process.ProcessName has no .exe suffix. The plugin is loaded
        // into one of these Solarpunk binaries.
        "SolarpunkSteam-Win64-Shipping",
        "Solarpunk-Win64-Shipping",
        "Solarpunk",
    };

    private void TryKillByPluginPid(int pid)
    {
        if (pid <= 0) return;
        try
        {
            using var p = Process.GetProcessById(pid);
            if (p.HasExited) return;

            // PID-reuse guard. SolarpunkPlugin.dll is loaded into the game process,
            // so the PluginPid reported on handshake must belong to one
            // of the game binaries. If the PID was recycled between the
            // handshake and the kill, the new owner's process name will
            // not match the game whitelist; refusing to kill prevents us
            // from terminating an unrelated user process. Case-insensitive
            // because Windows process names round-trip case unpredictably.
            var name = p.ProcessName ?? "";
            var isWhitelistedSp = false;
            foreach (var allowed in SpKillProcessNameWhitelist)
            {
                if (string.Equals(name, allowed, StringComparison.OrdinalIgnoreCase))
                {
                    isWhitelistedSp = true;
                    break;
                }
            }
            if (!isWhitelistedSp)
            {
                _log.LogWarning(
                    "FAIL-CLOSED (Lua): PluginPid={Pid} now belongs to '{Name}' (not Solarpunk); refusing to kill",
                    pid, name);
                return;
            }

            _log.LogWarning("FAIL-CLOSED (Lua): killing Solarpunk plugin host pid={Pid} name={Name} via PluginPid path", pid, name);
            p.Kill(entireProcessTree: false);
        }
        catch (ArgumentException)
        {
            // pid no longer exists — race with normal supervisor exit
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "FAIL-CLOSED (Lua): KillByPluginPid({Pid}) failed", pid);
        }
    }

    // Tracks the last staleness state we logged so we emit one line on each
    // transition (fresh -> stale, stale -> fresh) rather than spamming every tick.
    private bool _heartbeatStale;

    private void CheckHeartbeatStale()
    {
        var conn = _state.Connection;
        if (conn is null) return;
        var last = _state.LastHeartbeatAt;
        if (last is null) return;
        var age = DateTimeOffset.UtcNow - last.Value;
        var stale = age > _timeout;

        _log.LogDebug("Heartbeat: instance={Instance} pid={Pid} age={Age}s stale={Stale}",
            conn.InstanceId, conn.PluginPid, (int)age.TotalSeconds, stale);

        if (stale && !_heartbeatStale)
        {
            _log.LogWarning("Plugin heartbeat went STALE: instance={Instance} pid={Pid} age={Age}s",
                conn.InstanceId, conn.PluginPid, (int)age.TotalSeconds);
        }
        else if (!stale && _heartbeatStale)
        {
            _log.LogInformation("Plugin heartbeat RECOVERED: instance={Instance} pid={Pid} age={Age}s",
                conn.InstanceId, conn.PluginPid, (int)age.TotalSeconds);
        }
        else if (stale)
        {
            // Keep the original per-tick warning as a Debug heartbeat-still-stale
            // line so verbose logs retain the continuous signal.
            _log.LogDebug("Plugin heartbeat still stale: instance={Instance} pid={Pid} age={Age}s",
                conn.InstanceId, conn.PluginPid, (int)age.TotalSeconds);
        }

        _heartbeatStale = stale;
    }

    private void CheckServerPasswordReady()
    {
        // Steady-state under the Lua-only enforcement model is
        // ServerPasswordConfigured=0 across the entire fleet. The native
        // ApproveLogin hook is intentionally disabled (plugin-config.json
        // always has an empty ServerPassword), so if the plugin EVER
        // reports Configured=1, something upstream is broken and we
        // could be heading for the Solarpunk crash loop that necessitated
        // the pivot to Lua-only enforcement in the first place. Treat that
        // as a fail-closed condition.
        var conn = _state.Connection;
        if (conn is null) return;

        // Wait for the bootstrap-grace window after first contact. The
        // plugin's bootstrap thread populates the heartbeat fields
        // shortly after the handshake; first heartbeat or two can race.
        var sinceConnect = DateTimeOffset.UtcNow - conn.ConnectedAt;
        if (sinceConnect < AuthGraceWindow) return;

        // Plugin reporting Configured=0 is the expected steady state.
        // Nothing to do.
        if (_state.LastServerPasswordConfigured == 0) return;

        // Plugin says "I see ServerPassword in plugin-config.json." Under
        // the Lua-only model this should be impossible — EmitPluginConfig
        // hardcodes ServerPassword="". A non-zero value here means a stale
        // config from a previous deploy, a manually-edited plugin-config.json,
        // or a Solarpunk update that regressed EmitPluginConfig. Stop the game
        // before native + Lua enforcement layers race into the crash.
        var now = DateTimeOffset.UtcNow;
        var sinceWarn = now - _lastFailClosedWarnAt;
        if (sinceWarn > TimeSpan.FromSeconds(15))
        {
            _log.LogCritical(
                "FAIL-CLOSED: native plugin reported ServerPasswordConfigured={Configured} " +
                "hookReady={Ready}, but Solarpunk enforces password in SolarpunkAuth.lua only " +
                "and emits an empty ServerPassword in plugin-config.json. This usually means a " +
                "stale plugin-config.json from an earlier deploy or a manually-edited config. " +
                "Stopping Solarpunk to prevent the native gate from racing with the Lua gate " +
                "(which reproduces the Solarpunk fatal crash loop). Fix plugin-config.json " +
                "ServerPassword field to empty and restart.",
                _state.LastServerPasswordConfigured, _state.LastServerPasswordHookReady);
            _lastFailClosedWarnAt = now;
        }

        // Kill the game. Path-scoped KillGame covers standalone deploys (where
        // GameInstallRoot is configured); PluginPid-based kill covers
        // panel-managed deploys (where GameInstallRoot is intentionally
        // empty and KillGame logs "no anchor to scope by"). The IPC
        // handshake gives us the exact game PID — SolarpunkPlugin.dll calls
        // GetCurrentProcessId() inside the game process when sending
        // handshake.
        try
        {
            _coordinator.KillGame(TimeSpan.FromSeconds(10));
            TryKillByPluginPid(conn.PluginPid);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "FAIL-CLOSED: KillGame / KillByPluginPid threw");
        }
    }
}
