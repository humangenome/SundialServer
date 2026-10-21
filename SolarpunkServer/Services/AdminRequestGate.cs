using System.Security.Cryptography;

namespace SolarpunkServer.Services;

/// <summary>What the admin HTTP API does with a request, decided before any body byte is read.</summary>
public enum GateVerdict
{
    /// <summary>Missing, malformed, stale, replayed or wrong signature: 401.</summary>
    Unauthorized,
    /// <summary>Declared body larger than <c>MaxUploadBytes</c>: 413.</summary>
    TooLarge,
    /// <summary>A body of unknown length without a signed content hash: 411.</summary>
    LengthRequired,
    /// <summary>A body over <see cref="AdminRequestGate.SmallBodyMaxBytes"/> without a signed content hash: 428.</summary>
    ContentShaRequired,
    /// <summary>Small body: read it into memory (bounded), then verify the signature over its hash.</summary>
    ReadThenVerify,
    /// <summary>The signature over the declared content hash is already verified and recorded; stream the body and compare hashes.</summary>
    StreamPreverified,
}

public readonly record struct GateDecision(GateVerdict Verdict, long Timestamp, string? ContentSha256);

/// <summary>Which request limiter a request counts against.</summary>
public enum RouteClass
{
    Public,
    Signed,
}

/// <summary>Thrown when a body grows past its declared length or the upload cap.</summary>
public sealed class BodyTooLargeException : Exception
{
}

/// <summary>
/// The admin HTTP API's entry checks, kept free of <c>HttpListener</c> so they can be tested.
///
/// Rule: nobody gets the server to store more than <see cref="SmallBodyMaxBytes"/> of a request
/// before the request is authenticated. A small body (the JSON admin calls) is read into memory
/// and its signature checked over its hash, as before. A larger body (snapshot uploads) must
/// carry its SHA-256 in <see cref="ContentShaHeader"/>; that hash is what the signature covers,
/// so the signature and the replay window are checked from the headers alone, and only then is
/// the body streamed to disk and its real hash compared with the declared one.
/// The canonical string itself is unchanged (<see cref="HmacRequestAuth.CanonicalString"/>).
/// </summary>
public static class AdminRequestGate
{
    public const string TimestampHeader = "X-Solarpunk-Timestamp";
    public const string SignatureHeader = "X-Solarpunk-Signature";
    public const string ContentShaHeader = "X-Solarpunk-Content-Sha256";

    /// <summary>Largest body read before the signature is checked. Every JSON admin call fits.</summary>
    public const long SmallBodyMaxBytes = 64 * 1024;

    public static readonly string EmptyBodySha256 =
        Convert.ToHexString(SHA256.HashData(Array.Empty<byte>())).ToLowerInvariant();

    private static readonly HashSet<string> PublicGetPaths = new(StringComparer.Ordinal)
    {
        "/api/v1/health",
        "/api/v1/players",
        "/api/v1/manifest",
        "/api/v1/chat/motd",
        "/map/",
        "/map",
        "/map/index.html",
    };

    /// <summary>
    /// Public reads (what the panel and the launcher poll without a key) get their own request
    /// slots, so requests aimed at the signed routes can never starve the health check.
    /// </summary>
    public static RouteClass Classify(string method, string path, bool mapStateIsPublic)
    {
        if (!string.Equals(method, "GET", StringComparison.Ordinal)) return RouteClass.Signed;
        if (PublicGetPaths.Contains(path)) return RouteClass.Public;
        if (mapStateIsPublic && string.Equals(path, "/api/v1/map/state", StringComparison.Ordinal)) return RouteClass.Public;
        return RouteClass.Signed;
    }

    /// <summary>Everything that can be decided from the request line and headers.</summary>
    /// <param name="contentLength">The declared Content-Length, or -1 when unknown (chunked).</param>
    /// <param name="hasBody">Whether the request carries an entity body at all.</param>
    public static GateDecision Precheck(
        byte[] key,
        ReplayGuard replay,
        string method,
        string path,
        string? timestampHeader,
        string? signatureHeader,
        string? contentShaHeader,
        long contentLength,
        bool hasBody,
        long maxUploadBytes,
        long nowUnixSeconds)
    {
        if (key.Length == 0) return Deny();
        if (string.IsNullOrWhiteSpace(timestampHeader) || string.IsNullOrWhiteSpace(signatureHeader)) return Deny();
        if (!long.TryParse(timestampHeader.Trim(), out var ts)) return Deny();
        if (!replay.IsTimestampInWindow(ts, nowUnixSeconds)) return Deny();
        if (contentLength > maxUploadBytes) return new GateDecision(GateVerdict.TooLarge, ts, null);

        if (!string.IsNullOrWhiteSpace(contentShaHeader))
        {
            var declared = NormalizeSha256(contentShaHeader);
            if (declared is null) return Deny();
            var expected = HmacRequestAuth.Sign(key, HmacRequestAuth.CanonicalString(method, path, ts, declared));
            if (!HmacRequestAuth.SignatureMatches(expected, signatureHeader)) return Deny();
            if (!replay.TryAccept(signatureHeader, ts, nowUnixSeconds)) return Deny();
            return new GateDecision(GateVerdict.StreamPreverified, ts, declared);
        }

        if (hasBody && contentLength < 0) return new GateDecision(GateVerdict.LengthRequired, ts, null);
        if (contentLength > SmallBodyMaxBytes) return new GateDecision(GateVerdict.ContentShaRequired, ts, null);
        return new GateDecision(GateVerdict.ReadThenVerify, ts, null);
    }

    /// <summary>The small-body path: the bounded body has been read, check its signature now.</summary>
    public static bool VerifyBuffered(
        byte[] key,
        ReplayGuard replay,
        string method,
        string path,
        long timestamp,
        string? signatureHeader,
        string bodySha256Hex,
        long nowUnixSeconds)
    {
        if (key.Length == 0 || string.IsNullOrWhiteSpace(signatureHeader)) return false;
        var expected = HmacRequestAuth.Sign(key, HmacRequestAuth.CanonicalString(method, path, timestamp, bodySha256Hex));
        if (!HmacRequestAuth.SignatureMatches(expected, signatureHeader)) return false;
        return replay.TryAccept(signatureHeader, timestamp, nowUnixSeconds);
    }

    /// <summary>Lower-case 64-hex SHA-256, or null when the value is not one.</summary>
    public static string? NormalizeSha256(string? value)
    {
        if (value is null) return null;
        var v = value.Trim().ToLowerInvariant();
        if (v.Length != 64) return null;
        foreach (var c in v)
        {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return null;
        }
        return v;
    }

    /// <summary>
    /// Reads a small body into memory. Never reads past <paramref name="maxBytes"/> or past the
    /// declared length; throws <see cref="BodyTooLargeException"/> instead.
    /// </summary>
    public static async Task<byte[]> ReadSmallAsync(Stream input, long declaredLength, long maxBytes, CancellationToken ct)
    {
        if (declaredLength <= 0) return Array.Empty<byte>();
        if (declaredLength > maxBytes) throw new BodyTooLargeException();
        var buffer = new byte[declaredLength];
        var total = 0;
        while (total < buffer.Length)
        {
            var n = await input.ReadAsync(buffer.AsMemory(total, buffer.Length - total), ct).ConfigureAwait(false);
            if (n <= 0) break;
            total += n;
        }
        if (total < buffer.Length) Array.Resize(ref buffer, total);
        return buffer;
    }

    /// <summary>
    /// Streams a body to <paramref name="tempPath"/> while hashing it, in 64 KB chunks. The file
    /// is deleted on every failure (cap overflow, more bytes than declared, a read or write error,
    /// cancellation), so an aborted upload leaves nothing behind.
    /// </summary>
    /// <param name="declaredLength">The declared Content-Length, or -1 when unknown.</param>
    public static async Task<(string Sha256Hex, long Bytes)> CopyToFileAsync(
        Stream input, string tempPath, long declaredLength, long maxBytes, CancellationToken ct)
    {
        long total = 0;
        try
        {
            await using var fs = new FileStream(
                tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, useAsync: true);
            using var hasher = SHA256.Create();
            var buf = new byte[64 * 1024];
            if (declaredLength != 0)
            {
                while (true)
                {
                    var n = await input.ReadAsync(buf, ct).ConfigureAwait(false);
                    if (n <= 0) break;
                    total += n;
                    if (total > maxBytes) throw new BodyTooLargeException();
                    if (declaredLength > 0 && total > declaredLength) throw new BodyTooLargeException();
                    hasher.TransformBlock(buf, 0, n, null, 0);
                    await fs.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                }
            }
            hasher.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
            return (Convert.ToHexString(hasher.Hash!).ToLowerInvariant(), total);
        }
        catch
        {
            try { File.Delete(tempPath); } catch { }
            throw;
        }
    }

    private static GateDecision Deny() => new(GateVerdict.Unauthorized, 0, null);
}
