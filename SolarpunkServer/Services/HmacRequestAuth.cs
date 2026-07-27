using System.Security.Cryptography;
using System.Text;

namespace SolarpunkServer.Services;

/// <summary>
/// Signing rules for the admin HTTP API. The canonical string is fixed by
/// <c>protocol/</c> and by every existing client, so treat it as a wire
/// contract: changing the shape, the separator or the casing invalidates every
/// signature in the wild.
/// </summary>
public static class HmacRequestAuth
{
    /// <summary>
    /// <c>{METHOD}\n{path}\n{unixSeconds}\n{sha256(body) as lower hex}</c>.
    /// An empty body still contributes the SHA256 of zero bytes.
    /// </summary>
    public static string CanonicalString(string method, string path, long unixSeconds, string bodySha256Hex)
        => $"{method}\n{path}\n{unixSeconds}\n{bodySha256Hex}";

    /// <summary>HMAC-SHA256 over the canonical string, lower hex.</summary>
    public static string Sign(byte[] key, string canonical)
        => Convert.ToHexString(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();

    /// <summary>
    /// Constant-time comparison of the expected signature against what the
    /// caller sent. Length mismatch is a plain false, never an exception.
    /// </summary>
    public static bool SignatureMatches(string expected, string? provided)
    {
        if (string.IsNullOrEmpty(provided)) return false;
        return CryptographicOperations.FixedTimeEquals(
            Encoding.ASCII.GetBytes(expected),
            Encoding.ASCII.GetBytes(provided.ToLowerInvariant()));
    }
}

/// <summary>
/// Sliding window of signatures already accepted, so a captured valid request
/// cannot be replayed inside the freshness window to double-trigger a restore
/// or pile up snapshots. Entries older than the window are pruned lazily on
/// each accept, which bounds the table without a timer.
/// </summary>
public sealed class ReplayGuard
{
    private readonly int _windowSeconds;
    private readonly Dictionary<string, long> _seen = new(StringComparer.Ordinal);
    private readonly object _lock = new();

    public ReplayGuard(int windowSeconds)
    {
        if (windowSeconds <= 0) throw new ArgumentOutOfRangeException(nameof(windowSeconds));
        _windowSeconds = windowSeconds;
    }

    public int WindowSeconds => _windowSeconds;

    /// <summary>
    /// Symmetric window: a timestamp too far in the past OR the future is
    /// rejected, so a client with a badly skewed clock fails loudly rather
    /// than minting signatures that stay valid for hours.
    /// </summary>
    public bool IsTimestampInWindow(long unixSeconds, long nowUnixSeconds)
        => Math.Abs(nowUnixSeconds - unixSeconds) <= _windowSeconds;

    /// <summary>
    /// Records a signature as used. Returns false when this exact signature
    /// was already accepted and has not yet aged out.
    /// </summary>
    public bool TryAccept(string signature, long unixSeconds, long nowUnixSeconds)
    {
        var key = signature.ToLowerInvariant();
        lock (_lock)
        {
            if (_seen.Count > 0)
            {
                var cutoff = nowUnixSeconds - _windowSeconds;
                var stale = _seen.Where(kv => kv.Value < cutoff).Select(kv => kv.Key).ToList();
                foreach (var k in stale) _seen.Remove(k);
            }
            if (_seen.ContainsKey(key)) return false;
            _seen[key] = unixSeconds;
            return true;
        }
    }

    /// <summary>Signatures currently held. Exposed so the pruning is testable.</summary>
    public int TrackedCount
    {
        get { lock (_lock) return _seen.Count; }
    }
}
