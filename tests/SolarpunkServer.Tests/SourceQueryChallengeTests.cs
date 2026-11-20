using System.Buffers.Binary;
using System.Net;
using System.Text;
using FluentAssertions;
using Solarpunk.SourceQuery;
using Xunit;

namespace SolarpunkServer.Tests;

// Every A2S query needs a challenge first (A2S_INFO too, as on Valve's own servers since 2020), and a
// request without a valid one only ever gets the 9-byte challenge reply. A forged sender address
// therefore gets back less than it sent, so the query port cannot be used to flood someone else.
// Challenges come from the asker's address and the time, so nothing is stored per asker, and each
// address has a small reply budget on top.
public sealed class SourceQueryChallengeTests
{
    private static readonly IPEndPoint Asker = new(IPAddress.Parse("203.0.113.10"), 50000);
    private static readonly IPEndPoint OtherAsker = new(IPAddress.Parse("203.0.113.20"), 50000);

    private long _now = 1_000_000;

    private SourceQueryServer NewServer(Func<bool>? available = null, ReplyLimits? limits = null, List<string>? notices = null) =>
        new(0,
            () => new ServerInfoSnapshot("Test Garden", "MainLevel", "solarpunk", "Solarpunk", 1805110,
                1, 6, false, false, "sundial-0.1.102/sp-1", 7777, "sundial"),
            () => new[] { new PlayerInfoEntry("Player One", 0, 12f) },
            () => new[] { new KeyValuePair<string, string>("sundial_version", "0.1.102") },
            available,
            queryObserver: null,
            ignoreClosedPortReports: true,
            notice: notices is null ? null : notices.Add,
            limits: limits ?? new ReplyLimits(Burst: 1000, PerSecond: 1000, MaxTrackedAddresses: 8192),
            nowMs: () => _now);

    private static byte[] InfoRequest(int? challenge = null)
    {
        var body = Encoding.ASCII.GetBytes("Source Engine Query\0");
        var q = new byte[5 + body.Length + (challenge is null ? 0 : 4)];
        BinaryPrimitives.WriteInt32LittleEndian(q, -1);
        q[4] = 0x54;
        body.CopyTo(q, 5);
        if (challenge is { } c) BinaryPrimitives.WriteInt32LittleEndian(q.AsSpan(5 + body.Length), c);
        return q;
    }

    private static byte[] PlayerOrRulesRequest(byte header, int challenge)
    {
        var q = new byte[9];
        BinaryPrimitives.WriteInt32LittleEndian(q, -1);
        q[4] = header;
        BinaryPrimitives.WriteInt32LittleEndian(q.AsSpan(5), challenge);
        return q;
    }

    private static int ChallengeOf(byte[]? reply)
    {
        reply.Should().NotBeNull();
        reply!.Length.Should().Be(9);
        reply[4].Should().Be(0x41, "a challenge reply starts with 'A'");
        return BinaryPrimitives.ReadInt32LittleEndian(reply.AsSpan(5));
    }

    [Fact]
    public void Info_without_a_challenge_gets_only_a_challenge_then_the_info_with_it()
    {
        using var server = NewServer();
        var first = server.HandleQuery(Asker, InfoRequest());
        var challenge = ChallengeOf(first);
        first!.Length.Should().BeLessThan(InfoRequest().Length, "the challenge reply is smaller than the ask");

        var info = server.HandleQuery(Asker, InfoRequest(challenge));
        info.Should().NotBeNull();
        info![4].Should().Be(0x49, "with the challenge the asker gets the server info");
        Encoding.UTF8.GetString(info).Should().Contain("Test Garden");
    }

    // The two info asks a forged sender can send cheaply: the bare 5-byte header gets nothing at all, and the
    // standard 25-byte ask without a challenge gets only the 9-byte challenge, never the server info.
    [Fact]
    public void A_raw_info_ask_never_gets_the_server_info()
    {
        using var server = NewServer();
        server.HandleQuery(Asker, new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0x54 }).Should().BeNull("a bare header is not an info ask");

        var reply = server.HandleQuery(Asker, InfoRequest());
        reply.Should().NotBeNull();
        reply!.Length.Should().Be(9);
        reply[4].Should().Be(0x41, "an info ask without a challenge gets S2C_CHALLENGE");
        reply.Length.Should().BeLessThan(InfoRequest().Length);
    }

    [Fact]
    public void A_wrong_or_minus_one_challenge_gets_a_fresh_challenge_never_the_info()
    {
        using var server = NewServer();
        var right = ChallengeOf(server.HandleQuery(Asker, InfoRequest()));
        ChallengeOf(server.HandleQuery(Asker, InfoRequest(-1))).Should().Be(right);
        ChallengeOf(server.HandleQuery(Asker, InfoRequest(unchecked(right + 1)))).Should().Be(right);
    }

    [Fact]
    public void A_challenge_only_works_for_the_address_it_was_given_to()
    {
        using var server = NewServer();
        var mine = ChallengeOf(server.HandleQuery(Asker, InfoRequest()));
        var reply = server.HandleQuery(OtherAsker, InfoRequest(mine));
        ChallengeOf(reply).Should().NotBe(mine);
    }

    [Fact]
    public void A_challenge_lasts_at_least_30_seconds_and_runs_out_within_a_minute()
    {
        using var server = NewServer();
        _now = 30_000 * 100;                          // start of a window
        var challenge = ChallengeOf(server.HandleQuery(Asker, InfoRequest()));

        _now += 59_999;                               // end of the next window: still good
        server.HandleQuery(Asker, InfoRequest(challenge))![4].Should().Be(0x49);

        _now += 1;                                    // two windows on: a new one is handed out
        var next = ChallengeOf(server.HandleQuery(Asker, InfoRequest(challenge)));
        next.Should().NotBe(challenge);
        server.HandleQuery(Asker, InfoRequest(next))![4].Should().Be(0x49);
    }

    [Theory]
    [InlineData(0x55, 0x44)]
    [InlineData(0x56, 0x45)]
    public void Player_and_rules_lists_need_the_challenge(byte header, byte replyType)
    {
        using var server = NewServer();
        var challenge = ChallengeOf(server.HandleQuery(Asker, PlayerOrRulesRequest(header, -1)));
        var reply = server.HandleQuery(Asker, PlayerOrRulesRequest(header, challenge));
        reply.Should().NotBeNull();
        reply![4].Should().Be(replyType);

        // A challenge another address was given does not open the list either.
        var other = ChallengeOf(server.HandleQuery(OtherAsker, PlayerOrRulesRequest(header, -1)));
        ChallengeOf(server.HandleQuery(Asker, PlayerOrRulesRequest(header, other)));
    }

    [Fact]
    public void The_info_challenge_and_the_list_challenge_are_the_same_number()
    {
        // One challenge per address and time: a client that got one from A2S_INFO can use it for the
        // player list, as Valve's servers allow.
        using var server = NewServer();
        var challenge = ChallengeOf(server.HandleQuery(Asker, InfoRequest()));
        server.HandleQuery(Asker, PlayerOrRulesRequest(0x55, challenge))![4].Should().Be(0x44);
    }

    [Fact]
    public void Forged_asks_never_reach_the_game_check_and_an_offline_server_gives_no_info()
    {
        var checks = 0;
        using var server = NewServer(available: () => { checks++; return false; });
        for (var i = 0; i < 50; i++) ChallengeOf(server.HandleQuery(Asker, InfoRequest()));
        checks.Should().Be(0, "a request without a valid challenge is answered without looking at the game");

        var challenge = ChallengeOf(server.HandleQuery(Asker, InfoRequest()));
        server.HandleQuery(Asker, InfoRequest(challenge)).Should().BeNull("an offline server gives no info");
        server.HandleQuery(Asker, PlayerOrRulesRequest(0x55, challenge)).Should().BeNull();
        checks.Should().Be(2);
    }

    [Theory]
    [InlineData(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0x54 })]
    [InlineData(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0x54, (byte)'X', 0 })]
    [InlineData(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0x55, 1, 2 })]
    [InlineData(new byte[] { 0xFF, 0xFF, 0xFF, 0xFE, 0x54 })]
    [InlineData(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF, 0x57, 0xFF, 0xFF, 0xFF, 0xFF })]
    public void Anything_else_gets_no_reply(byte[] payload)
    {
        using var server = NewServer();
        server.HandleQuery(Asker, payload).Should().BeNull();
    }

    [Fact]
    public void A_challenge_is_never_minus_one()
    {
        using var server = NewServer();
        for (var window = 0; window < 20_000; window++)
            server.ChallengeFor(IPAddress.Parse("198.51.100.7"), window).Should().NotBe(-1);
    }

    [Fact]
    public void Each_address_has_a_reply_budget_that_refills()
    {
        var notices = new List<string>();
        using var server = NewServer(limits: new ReplyLimits(Burst: 5, PerSecond: 2, MaxTrackedAddresses: 64), notices: notices);
        for (var i = 0; i < 5; i++) server.HandleQuery(Asker, InfoRequest()).Should().NotBeNull();
        server.HandleQuery(Asker, InfoRequest()).Should().BeNull("the sixth ask at once is over the budget");
        server.HandleQuery(OtherAsker, InfoRequest()).Should().NotBeNull("another address has its own budget");
        server.RepliesRefused.Should().Be(1);

        _now += 500;                                  // half a second refills one reply
        server.HandleQuery(Asker, InfoRequest()).Should().NotBeNull();
        server.HandleQuery(Asker, InfoRequest()).Should().BeNull();

        // One plain line at most once a minute, counting the asks dropped since the last line.
        notices.Should().BeEmpty();
        _now += 60_000;
        for (var i = 0; i < 6; i++) server.HandleQuery(Asker, InfoRequest());
        notices.Should().ContainSingle().Which.Should().Contain("2 asks went unanswered");
    }

    [Fact]
    public void A_full_table_forgets_quiet_addresses_but_does_not_let_a_flood_of_new_ones_in()
    {
        using var server = NewServer(limits: new ReplyLimits(Burst: 4, PerSecond: 2, MaxTrackedAddresses: 3));
        IPEndPoint At(int n) => new(IPAddress.Parse("198.51.100." + n), 40000);

        for (var n = 1; n <= 3; n++) server.HandleQuery(At(n), InfoRequest()).Should().NotBeNull();
        server.TrackedAddresses.Should().Be(3);
        server.HandleQuery(At(4), InfoRequest()).Should().BeNull("the table is full of addresses that asked just now");

        _now += 2_000;                                // their budgets have refilled: they are quiet now
        server.HandleQuery(At(4), InfoRequest()).Should().NotBeNull("quiet addresses make room");
        server.TrackedAddresses.Should().Be(1);
    }

    // The reply budget must never become a table that grows with every forged sender. 200,000 forged
    // senders, a different address each, 20 a millisecond for 10 seconds, against the real limits.
    [Fact]
    public void A_flood_of_forged_senders_never_grows_the_table_past_its_cap()
    {
        var limits = ReplyLimits.Default;             // 20 at once, 5 a second, 8,192 addresses
        using var server = NewServer(limits: limits);
        var player = new IPEndPoint(IPAddress.Parse("192.0.2.50"), 50000);
        var ask = InfoRequest();
        server.HandleQuery(player, ask).Should().NotBeNull();

        const int forged = 200_000;
        var maxTracked = 0;
        var playerMissed = 0;
        for (var i = 0; i < forged; i++)
        {
            if (i % 20 == 0) _now += 1;
            var sender = new IPEndPoint(new IPAddress(new byte[] { 10, (byte)(i >> 16), (byte)(i >> 8), (byte)i }), 40000 + i % 1000);
            server.HandleQuery(sender, ask);
            maxTracked = Math.Max(maxTracked, server.TrackedAddresses);
            // The real player asks once a (simulated) second throughout.
            if (i % 20_000 == 0 && server.HandleQuery(player, ask) is null) playerMissed++;
        }

        maxTracked.Should().Be(limits.MaxTrackedAddresses, "the flood fills the table but never past its cap");
        server.RepliesRefused.Should().BeGreaterThan(forged / 2, "once the table is full, new senders are refused, not added");
        playerMissed.Should().Be(0, "an address already in the table keeps its budget through the flood");

        // When the flood stops, quiet addresses are dropped at the next sweep and a new sender is answered.
        _now += 15_000;
        server.HandleQuery(new IPEndPoint(IPAddress.Parse("192.0.2.77"), 50000), ask).Should().NotBeNull();
        server.TrackedAddresses.Should().Be(1);
    }

    [Fact]
    public void Quiet_addresses_are_dropped_on_the_ten_second_sweep_even_when_the_table_is_not_full()
    {
        using var server = NewServer(limits: new ReplyLimits(Burst: 4, PerSecond: 2, MaxTrackedAddresses: 1000));
        for (var n = 1; n <= 50; n++)
            server.HandleQuery(new IPEndPoint(IPAddress.Parse("198.51.100." + n), 40000), InfoRequest()).Should().NotBeNull();
        server.TrackedAddresses.Should().Be(50);

        _now += 10_000;                               // everyone quiet for longer than a refill (2 s)
        server.HandleQuery(new IPEndPoint(IPAddress.Parse("198.51.100.200"), 40000), InfoRequest()).Should().NotBeNull();
        server.TrackedAddresses.Should().Be(1);
    }
}
