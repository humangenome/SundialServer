using System.Security.Cryptography;
using System.Text;
using FluentAssertions;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// The admin HTTP API authenticates before it stores a body: small bodies are read
/// (bounded) and checked, large bodies must carry a signed content hash that is checked
/// from the headers alone. These tests pin that order and the temp-file cleanup.
/// </summary>
public class AdminRequestGateTests
{
    private static readonly byte[] Key = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
    private const long Now = 1_800_000_000;
    private const long MaxUpload = 2L * 1024 * 1024 * 1024;

    private static string Sha(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private static string SignFor(string method, string path, long ts, string bodySha)
        => HmacRequestAuth.Sign(Key, HmacRequestAuth.CanonicalString(method, path, ts, bodySha));

    private static GateDecision Pre(ReplayGuard g, string? ts, string? sig, string? contentSha, long length, bool hasBody,
        string method = "POST", string path = "/api/v1/snapshots")
        => AdminRequestGate.Precheck(Key, g, method, path, ts, sig, contentSha, length, hasBody, MaxUpload, Now);

    [Fact]
    public void No_signature_headers_is_unauthorized_before_any_body_is_read()
    {
        var g = new ReplayGuard(300);
        Pre(g, null, null, null, 2_000_000_000, true).Verdict.Should().Be(GateVerdict.Unauthorized);
        Pre(g, Now.ToString(), null, null, 10, true).Verdict.Should().Be(GateVerdict.Unauthorized);
        Pre(g, null, "abc", null, 10, true).Verdict.Should().Be(GateVerdict.Unauthorized);
    }

    [Fact]
    public void A_stale_or_unparsable_timestamp_is_unauthorized()
    {
        var g = new ReplayGuard(300);
        Pre(g, (Now - 301).ToString(), "abc", null, 0, false).Verdict.Should().Be(GateVerdict.Unauthorized);
        Pre(g, (Now + 301).ToString(), "abc", null, 0, false).Verdict.Should().Be(GateVerdict.Unauthorized);
        Pre(g, "soon", "abc", null, 0, false).Verdict.Should().Be(GateVerdict.Unauthorized);
    }

    [Fact]
    public void A_large_body_with_a_made_up_signature_and_no_content_hash_is_refused_unread()
    {
        var g = new ReplayGuard(300);
        var d = Pre(g, Now.ToString(), new string('a', 64), null, 1_000_000, true);
        d.Verdict.Should().Be(GateVerdict.ContentShaRequired);
        g.TrackedCount.Should().Be(0, "a refused request must not use up a signature");
    }

    [Fact]
    public void The_small_body_limit_is_64_KB()
    {
        var g = new ReplayGuard(300);
        Pre(g, Now.ToString(), "abc", null, AdminRequestGate.SmallBodyMaxBytes, true).Verdict.Should().Be(GateVerdict.ReadThenVerify);
        Pre(g, Now.ToString(), "abc", null, AdminRequestGate.SmallBodyMaxBytes + 1, true).Verdict.Should().Be(GateVerdict.ContentShaRequired);
    }

    [Fact]
    public void A_body_of_unknown_length_without_a_content_hash_is_refused()
    {
        var g = new ReplayGuard(300);
        Pre(g, Now.ToString(), "abc", null, -1, true).Verdict.Should().Be(GateVerdict.LengthRequired);
    }

    [Fact]
    public void No_body_and_unknown_length_is_a_plain_small_request()
    {
        var g = new ReplayGuard(300);
        Pre(g, Now.ToString(), "abc", null, -1, false, "GET", "/api/v1/info").Verdict.Should().Be(GateVerdict.ReadThenVerify);
    }

    [Fact]
    public void Over_the_upload_cap_is_too_large_even_when_signed()
    {
        var g = new ReplayGuard(300);
        var sha = new string('b', 64);
        Pre(g, Now.ToString(), SignFor("POST", "/api/v1/snapshots", Now, sha), sha, MaxUpload + 1, true)
            .Verdict.Should().Be(GateVerdict.TooLarge);
    }

    [Fact]
    public void A_wrong_signature_over_a_declared_hash_is_unauthorized_unread()
    {
        var g = new ReplayGuard(300);
        var sha = new string('c', 64);
        var wrongKey = Enumerable.Range(1, 32).Select(i => (byte)i).ToArray();
        var badSig = HmacRequestAuth.Sign(wrongKey, HmacRequestAuth.CanonicalString("POST", "/api/v1/snapshots", Now, sha));
        Pre(g, Now.ToString(), badSig, sha, 500_000_000, true).Verdict.Should().Be(GateVerdict.Unauthorized);
        g.TrackedCount.Should().Be(0);
    }

    [Fact]
    public void A_malformed_content_hash_header_is_unauthorized()
    {
        var g = new ReplayGuard(300);
        Pre(g, Now.ToString(), "abc", "not-a-hash", 100, true).Verdict.Should().Be(GateVerdict.Unauthorized);
        Pre(g, Now.ToString(), "abc", new string('z', 64), 100, true).Verdict.Should().Be(GateVerdict.Unauthorized);
    }

    [Fact]
    public void A_valid_signed_content_hash_is_verified_and_recorded_before_streaming()
    {
        var g = new ReplayGuard(300);
        var body = Encoding.UTF8.GetBytes(new string('x', 200_000));
        var sha = Sha(body);
        var sig = SignFor("POST", "/api/v1/snapshots", Now, sha);

        var d = Pre(g, Now.ToString(), sig, sha.ToUpperInvariant(), body.Length, true);

        d.Verdict.Should().Be(GateVerdict.StreamPreverified);
        d.ContentSha256.Should().Be(sha);
        d.Timestamp.Should().Be(Now);
        g.TrackedCount.Should().Be(1);
        Pre(g, Now.ToString(), sig, sha, body.Length, true).Verdict.Should().Be(GateVerdict.Unauthorized, "a replay is refused");
    }

    [Fact]
    public void Small_body_signature_is_checked_over_the_real_body_hash_and_replays_are_refused()
    {
        var g = new ReplayGuard(300);
        var body = Encoding.UTF8.GetBytes("{\"msg\":\"hello\"}");
        var sig = SignFor("POST", "/api/v1/chat/say", Now, Sha(body));

        AdminRequestGate.VerifyBuffered(Key, g, "POST", "/api/v1/chat/say", Now, sig, Sha(Encoding.UTF8.GetBytes("tampered")), Now)
            .Should().BeFalse();
        AdminRequestGate.VerifyBuffered(Key, g, "POST", "/api/v1/chat/say", Now, sig, Sha(body), Now).Should().BeTrue();
        AdminRequestGate.VerifyBuffered(Key, g, "POST", "/api/v1/chat/say", Now, sig, Sha(body), Now).Should().BeFalse();
    }

    [Fact]
    public void An_empty_key_never_authenticates()
    {
        var g = new ReplayGuard(300);
        AdminRequestGate.Precheck(Array.Empty<byte>(), g, "GET", "/api/v1/info", Now.ToString(), "abc", null, 0, false, MaxUpload, Now)
            .Verdict.Should().Be(GateVerdict.Unauthorized);
        AdminRequestGate.VerifyBuffered(Array.Empty<byte>(), g, "GET", "/api/v1/info", Now, "abc", AdminRequestGate.EmptyBodySha256, Now)
            .Should().BeFalse();
    }

    [Fact]
    public async Task ReadSmall_reads_exactly_the_declared_bytes_and_refuses_more_than_the_cap()
    {
        var data = Encoding.UTF8.GetBytes("abcdef");
        (await AdminRequestGate.ReadSmallAsync(new MemoryStream(data), data.Length, 64, CancellationToken.None))
            .Should().Equal(data);
        (await AdminRequestGate.ReadSmallAsync(new MemoryStream(data), 0, 64, CancellationToken.None)).Should().BeEmpty();
        var act = () => AdminRequestGate.ReadSmallAsync(new MemoryStream(data), 65, 64, CancellationToken.None);
        await act.Should().ThrowAsync<BodyTooLargeException>();
    }

    [Fact]
    public async Task CopyToFile_hashes_what_it_writes()
    {
        var path = TempFile();
        try
        {
            var data = Enumerable.Range(0, 300_000).Select(i => (byte)(i % 251)).ToArray();
            var (sha, bytes) = await AdminRequestGate.CopyToFileAsync(new MemoryStream(data), path, data.Length, 1_000_000, CancellationToken.None);
            sha.Should().Be(Sha(data));
            bytes.Should().Be(data.Length);
            File.ReadAllBytes(path).Should().Equal(data);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task CopyToFile_deletes_the_partial_file_when_the_cap_is_passed()
    {
        var path = TempFile();
        var data = new byte[200_000];
        var act = () => AdminRequestGate.CopyToFileAsync(new MemoryStream(data), path, -1, 100_000, CancellationToken.None);
        await act.Should().ThrowAsync<BodyTooLargeException>();
        File.Exists(path).Should().BeFalse();
    }

    [Fact]
    public async Task CopyToFile_deletes_the_partial_file_when_more_than_the_declared_length_arrives()
    {
        var path = TempFile();
        var data = new byte[200_000];
        var act = () => AdminRequestGate.CopyToFileAsync(new MemoryStream(data), path, 100_000, 1_000_000, CancellationToken.None);
        await act.Should().ThrowAsync<BodyTooLargeException>();
        File.Exists(path).Should().BeFalse();
    }

    [Fact]
    public async Task CopyToFile_deletes_the_partial_file_when_the_connection_fails()
    {
        var path = TempFile();
        var act = () => AdminRequestGate.CopyToFileAsync(new FailingStream(100_000), path, 500_000, 1_000_000, CancellationToken.None);
        await act.Should().ThrowAsync<IOException>();
        File.Exists(path).Should().BeFalse();
    }

    [Theory]
    [InlineData("GET", "/api/v1/health", false, RouteClass.Public)]
    [InlineData("GET", "/api/v1/players", false, RouteClass.Public)]
    [InlineData("GET", "/api/v1/manifest", false, RouteClass.Public)]
    [InlineData("GET", "/api/v1/chat/motd", false, RouteClass.Public)]
    [InlineData("GET", "/map/", false, RouteClass.Public)]
    [InlineData("GET", "/api/v1/map/state", false, RouteClass.Signed)]
    [InlineData("GET", "/api/v1/map/state", true, RouteClass.Public)]
    [InlineData("GET", "/api/v1/chat/recent", true, RouteClass.Signed)]
    [InlineData("POST", "/api/v1/chat/player", true, RouteClass.Signed)]
    [InlineData("POST", "/api/v1/health", true, RouteClass.Signed)]
    [InlineData("POST", "/api/v1/snapshots", true, RouteClass.Signed)]
    [InlineData("GET", "/api/v1/info", true, RouteClass.Signed)]
    public void Public_reads_get_their_own_request_slots(string method, string path, bool mapPublic, RouteClass expected)
    {
        AdminRequestGate.Classify(method, path, mapPublic).Should().Be(expected);
    }

    private static string TempFile()
        => Path.Combine(Path.GetTempPath(), $"sp-gate-test-{Guid.NewGuid():N}.bin");

    private sealed class FailingStream : Stream
    {
        private long _left;
        public FailingStream(long bytesBeforeFailure) { _left = bytesBeforeFailure; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => 0; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (_left <= 0) throw new IOException("connection reset");
            var n = (int)Math.Min(count, _left);
            _left -= n;
            return n;
        }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
