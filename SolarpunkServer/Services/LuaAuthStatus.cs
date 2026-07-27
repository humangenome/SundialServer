namespace SolarpunkServer.Services;

/// <summary>
/// Parsed contents of <c>.solarpunk-auth-status</c>, the file SolarpunkAuth.lua
/// republishes on a heartbeat. This is the authoritative signal that the
/// in-game password gate is loaded and enforcing, so
/// <see cref="HeartbeatWatchdogService"/> fail-closes a passworded server
/// whenever <see cref="IsGateReady"/> is false.
///
/// Format is one <c>key=value</c> per line:
///   ready=0|1
///   passwordConfigured=0|1
///   updated=&lt;unix seconds&gt;
///   reason=&lt;short string&gt;
///
/// Unknown keys are ignored, so the Lua side can add fields without breaking
/// an older supervisor.
/// </summary>
public readonly record struct LuaAuthStatus(
    bool Ready,
    bool PasswordConfigured,
    string Reason,
    bool Exists,
    DateTimeOffset? UpdatedAt)
{
    /// <summary>No status file on disk at all.</summary>
    public static LuaAuthStatus Missing { get; } = new(false, false, "file_missing", false, null);

    /// <summary>The file exists but could not be read.</summary>
    public static LuaAuthStatus ReadError { get; } = new(false, false, "read_error", false, null);

    public static LuaAuthStatus Parse(IEnumerable<string> lines)
    {
        var ready = false;
        var passwordConfigured = false;
        var reason = "";
        DateTimeOffset? updatedAt = null;

        foreach (var line in lines)
        {
            var eq = line.IndexOf('=');
            if (eq <= 0) continue;
            var key = line[..eq].Trim();
            var value = line[(eq + 1)..].Trim();
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

        return new LuaAuthStatus(ready, passwordConfigured, reason, true, updatedAt);
    }

    /// <summary>
    /// True only when the Lua side stamped a timestamp and that stamp is
    /// neither older than <paramref name="maxAge"/> nor in the future. A
    /// status file left behind by a dead game process therefore goes stale
    /// instead of holding the gate open.
    /// </summary>
    public bool IsFresh(TimeSpan maxAge, DateTimeOffset now)
    {
        if (UpdatedAt is null) return false;
        var age = now - UpdatedAt.Value;
        return age >= TimeSpan.Zero && age <= maxAge;
    }

    /// <summary>
    /// The single fail-closed predicate. Every condition must hold, so any
    /// missing, stale, not-ready or password-less status keeps the watchdog
    /// on its kill path.
    /// </summary>
    public bool IsGateReady(TimeSpan maxAge, DateTimeOffset now)
        => Exists && PasswordConfigured && Ready && IsFresh(maxAge, now);
}
