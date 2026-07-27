using System.Security.Cryptography;
using System.Text;
using FluentAssertions;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// Admin HTTP API signing. The canonical string is a wire contract shared with
/// every client, so these tests pin its exact shape as well as the behaviour.
/// </summary>
public class HmacRequestAuthTests
{
    private static readonly byte[] Key = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
    private const string EmptyBodySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    [Fact]
    public void Canonical_string_is_method_path_timestamp_bodyhash_newline_separated()
    {
        var canonical = HmacRequestAuth.CanonicalString("POST", "/snapshots", 1_800_000_000, EmptyBodySha);

        canonical.Should().Be($"POST\n/snapshots\n1800000000\n{EmptyBodySha}");
    }

    [Fact]
    public void Signature_is_lower_hex_hmac_sha256_over_the_canonical_string()
    {
        var canonical = HmacRequestAuth.CanonicalString("GET", "/snapshots", 1_800_000_000, EmptyBodySha);
        var expected = Convert.ToHexString(
            HMACSHA256.HashData(Key, Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();

        var actual = HmacRequestAuth.Sign(Key, canonical);

        actual.Should().Be(expected);
        actual.Should().MatchRegex("^[0-9a-f]{64}$");
    }

    [Fact]
    public void Signatures_accept_the_caller_using_upper_hex()
    {
        var canonical = HmacRequestAuth.CanonicalString("GET", "/players", 1_800_000_000, EmptyBodySha);
        var sig = HmacRequestAuth.Sign(Key, canonical);

        HmacRequestAuth.SignatureMatches(sig, sig.ToUpperInvariant()).Should().BeTrue();
    }

    [Theory]
    [InlineData("GET", "/snapshots", 1_800_000_000L, "method")]
    [InlineData("POST", "/snapshots/1/restore", 1_800_000_000L, "path")]
    [InlineData("POST", "/snapshots", 1_800_000_001L, "timestamp")]
    public void Changing_any_signed_component_changes_the_signature(string method, string path, long ts, string _)
    {
        var baseline = HmacRequestAuth.Sign(Key, HmacRequestAuth.CanonicalString("POST", "/snapshots", 1_800_000_000, EmptyBodySha));
        var altered = HmacRequestAuth.Sign(Key, HmacRequestAuth.CanonicalString(method, path, ts, EmptyBodySha));

        altered.Should().NotBe(baseline);
    }

    [Fact]
    public void Changing_the_body_changes_the_signature()
    {
        var otherBodySha = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("payload"))).ToLowerInvariant();

        var a = HmacRequestAuth.Sign(Key, HmacRequestAuth.CanonicalString("POST", "/snapshots", 1_800_000_000, EmptyBodySha));
        var b = HmacRequestAuth.Sign(Key, HmacRequestAuth.CanonicalString("POST", "/snapshots", 1_800_000_000, otherBodySha));

        b.Should().NotBe(a);
    }

    [Fact]
    public void A_different_key_does_not_verify()
    {
        var canonical = HmacRequestAuth.CanonicalString("GET", "/health", 1_800_000_000, EmptyBodySha);
        var wrongKey = Enumerable.Range(1, 32).Select(i => (byte)i).ToArray();

        HmacRequestAuth.SignatureMatches(
            HmacRequestAuth.Sign(Key, canonical),
            HmacRequestAuth.Sign(wrongKey, canonical)).Should().BeFalse();
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("deadbeef")]
    public void Empty_or_short_signatures_are_rejected_without_throwing(string? provided)
    {
        var expected = HmacRequestAuth.Sign(Key, HmacRequestAuth.CanonicalString("GET", "/health", 1_800_000_000, EmptyBodySha));

        HmacRequestAuth.SignatureMatches(expected, provided).Should().BeFalse();
    }
}

/// <summary>
/// The replay window. A captured-but-valid request must not be usable twice
/// inside its freshness window, which is what stops a replayed restore from
/// rolling a world back a second time.
/// </summary>
public class ReplayGuardTests
{
    private const long Now = 1_800_000_000;

    [Theory]
    [InlineData(0, true)]
    [InlineData(-299, true)]
    [InlineData(-300, true)]   // boundary is inclusive
    [InlineData(-301, false)]
    [InlineData(300, true)]    // symmetric: modest clock skew forward is allowed
    [InlineData(301, false)]   // but not an arbitrarily future timestamp
    public void Timestamp_window_is_symmetric_and_inclusive(int offset, bool expected)
    {
        new ReplayGuard(300).IsTimestampInWindow(Now + offset, Now).Should().Be(expected);
    }

    [Fact]
    public void The_same_signature_is_accepted_once_and_then_rejected()
    {
        var guard = new ReplayGuard(300);

        guard.TryAccept("abc123", Now, Now).Should().BeTrue();
        guard.TryAccept("abc123", Now, Now).Should().BeFalse();
        guard.TryAccept("abc123", Now, Now + 10).Should().BeFalse();
    }

    [Fact]
    public void Replay_detection_is_case_insensitive()
    {
        var guard = new ReplayGuard(300);

        guard.TryAccept("ABC123", Now, Now).Should().BeTrue();
        guard.TryAccept("abc123", Now, Now).Should().BeFalse();
    }

    [Fact]
    public void Distinct_signatures_are_all_accepted()
    {
        var guard = new ReplayGuard(300);

        for (var i = 0; i < 50; i++)
            guard.TryAccept($"sig{i}", Now, Now).Should().BeTrue();

        guard.TrackedCount.Should().Be(50);
    }

    [Fact]
    public void Entries_older_than_the_window_are_pruned_on_the_next_accept()
    {
        var guard = new ReplayGuard(300);
        guard.TryAccept("old", Now, Now).Should().BeTrue();
        guard.TrackedCount.Should().Be(1);

        guard.TryAccept("new", Now + 400, Now + 400).Should().BeTrue();

        guard.TrackedCount.Should().Be(1);
    }

    // Pruning must not become a replay hole while an entry is still inside its
    // own window, even as the clock advances.
    [Fact]
    public void An_entry_inside_the_window_is_still_a_replay_after_time_passes()
    {
        var guard = new ReplayGuard(300);
        guard.TryAccept("sig", Now, Now).Should().BeTrue();

        guard.TryAccept("sig", Now, Now + 299).Should().BeFalse();
    }

    [Fact]
    public void Concurrent_accepts_of_one_signature_admit_exactly_one()
    {
        var guard = new ReplayGuard(300);
        var accepted = 0;

        Parallel.For(0, 200, _ =>
        {
            if (guard.TryAccept("contended", Now, Now)) Interlocked.Increment(ref accepted);
        });

        accepted.Should().Be(1);
    }

    [Fact]
    public void A_non_positive_window_is_rejected()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new ReplayGuard(0));
        Assert.Throws<ArgumentOutOfRangeException>(() => new ReplayGuard(-1));
    }
}
