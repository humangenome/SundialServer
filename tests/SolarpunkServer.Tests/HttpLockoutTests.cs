using System.Security.Cryptography;
using System.Text;
using FluentAssertions;
using Microsoft.Extensions.Logging;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

// The HTTP door's wrong-signature limit, on the real service, from a real non-loopback address.
// The signed routes download and replace the world with a key derived from the RCON password, so
// they get the same limit as RCON, and the count is shared with RCON: five wrong signatures with a
// FRESH timestamp in ten minutes turn the address away (a stale timestamp is a clock problem, not a
// guess); a turned-away request is refused before its body is read; players' public routes and
// loopback stay open; the block is logged once.
[Collection("SourceGuard")]
public sealed class HttpLockoutTests : IDisposable
{
    public HttpLockoutTests() => TestNet.ResetGuard();
    public void Dispose() => TestNet.ResetGuard();

    [Fact]
    public async Task Five_fresh_wrong_signatures_turn_the_address_away_before_any_body_is_read()
    {
        var own = TestNet.OwnAddress();
        var log = new ListLogger<SolarpunkHttpService>();
        await using var h = await HttpLiveHarness.StartAsync(log);
        var wrongKey = SHA256.HashData(Encoding.UTF8.GetBytes("not-the-password"));
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var none = Array.Empty<byte>();

        // Stale timestamps with wrong signatures: a clock problem, never counted.
        for (var i = 0; i < 10; i++)
            (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 3600 - i, from: own, signKey: wrongKey))
                .Should().Be(401);
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now, from: own)).Should().Be(200);

        // Five wrong signatures with fresh timestamps.
        for (var i = 0; i < 5; i++)
            (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 10 - i, from: own, signKey: wrongKey))
                .Should().Be(401);

        // The address is turned away now, right signature or not, and an upload is refused unread.
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 1, from: own))
            .Should().Be(429, "five fresh wrong signatures turn the address away for a minute");
        var tempBefore = HttpLiveHarness.UploadTempFiles();
        var zip = new byte[200_000];
        RandomNumberGenerator.Fill(zip);
        (await h.SignedAsync("POST", "/api/v1/snapshots", zip, sendSha: true, ts: now - 2, from: own))
            .Should().BeOneOf(new[] { 429, -1 }, "a turned-away upload is refused (the server may close before the body is sent)");
        HttpLiveHarness.UploadTempFiles().Should().BeEquivalentTo(tempBefore, "a turned-away upload is never read to disk");
        Directory.EnumerateFiles(h.SaveDir, "*.zip", SearchOption.AllDirectories).Should().BeEmpty();

        // Players' public routes from that address, and the same request over loopback, still answer.
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        using var players = await http.GetAsync($"http://{own}:{h.Port}/api/v1/players");
        ((int)players.StatusCode).Should().Be(200);
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 3)).Should().Be(200, "loopback is never limited");

        // One block line at warning level, naming the address, the door and the length, nothing secret.
        var blocks = log.Entries.Where(e => e.Text.Contains("auth block")).ToList();
        blocks.Should().ContainSingle("one line per block, not one per wrong try");
        blocks[0].Level.Should().Be(LogLevel.Warning);
        blocks[0].Text.Should().Contain("door=http").And.Contain("address=" + own).And.Contain("blocked=60s");
        blocks[0].Text.Should().NotContain(HttpLiveHarness.Password).And.NotMatchRegex("[0-9a-f]{64}");
    }

    [Fact]
    public async Task A_good_signature_clears_the_count()
    {
        var own = TestNet.OwnAddress();
        await using var h = await HttpLiveHarness.StartAsync();
        var wrongKey = SHA256.HashData(Encoding.UTF8.GetBytes("not-the-password"));
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var none = Array.Empty<byte>();

        for (var i = 0; i < 4; i++)
            (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 10 - i, from: own, signKey: wrongKey)).Should().Be(401);
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now, from: own)).Should().Be(200);
        for (var i = 0; i < 4; i++)
            (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 20 - i, from: own, signKey: wrongKey)).Should().Be(401);
        (await h.SignedAsync("GET", "/api/v1/info", none, false, ts: now - 1, from: own))
            .Should().Be(200, "four wrong, one right, four wrong is never five in a row");
    }
}
