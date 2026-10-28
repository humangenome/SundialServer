using FluentAssertions;
using Solarpunk.Protocol;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// RCON kick, ban and players by the player's account id (0.1.97). Players who join by invite code
/// carry the Epic id the game keeps for them (32 hex characters); the roster publishes it as their
/// SolarpunkUserId. Many players share the game's default name ("Player 1"), so a name must never
/// turn into a ban on everyone who has it, and bans of the old synthetic ids keep working.
/// </summary>
public class RconPlayerIdTests
{
    private const string IdA = "00025a60dcf249c8899393a3f13e46b6";
    private const string IdB = "0002b54ef4294a8b832cf84bb6ad73da";
    private const string Synth = "765611900123456789";

    private static PlayerSnapshot P(string id, string name) => new(id, name, 0, 0, 0);

    [Fact]
    public void An_account_id_is_used_as_given_and_lowercased()
    {
        var (id, err) = RconHostedService.ResolveUserId(IdA.ToUpperInvariant(), Array.Empty<PlayerSnapshot>());
        id.Should().Be(IdA);
        err.Should().BeNull();
    }

    [Fact]
    public void A_synthetic_id_still_works_for_offline_players()
    {
        var (id, _) = RconHostedService.ResolveUserId(Synth, Array.Empty<PlayerSnapshot>());
        id.Should().Be(Synth);
    }

    [Fact]
    public void A_unique_name_resolves_to_that_players_account_id_not_a_name_hash()
    {
        var players = new[] { P(IdA, "Maple"), P(IdB, "Rowan") };
        var (id, _) = RconHostedService.ResolveUserId("maple", players);
        id.Should().Be(IdA);
    }

    [Fact]
    public void A_name_two_players_share_is_refused_with_a_pointer_to_the_ids()
    {
        var players = new[] { P(IdA, "Player 1"), P(IdB, "Player 1") };
        var (id, err) = RconHostedService.ResolveUserId("Player 1", players);
        id.Should().BeNull();
        err.Should().Contain("2 players are named 'Player 1'").And.Contain("id");
    }

    [Fact]
    public void An_unknown_name_is_refused()
    {
        var (id, err) = RconHostedService.ResolveUserId("Nobody", new[] { P(IdA, "Maple") });
        id.Should().BeNull();
        err.Should().Contain("no online player named 'Nobody'");
    }

    [Fact]
    public void An_address_joined_player_without_an_account_id_resolves_to_the_synthetic_id()
    {
        var (id, _) = RconHostedService.ResolveUserId("Oak", new[] { P(Synth, "Oak") });
        id.Should().Be(Synth);
    }

    [Theory]
    [InlineData("\"Player 1\" griefing", "Player 1", "griefing")]
    [InlineData("\"Player 1\"", "Player 1", "")]
    [InlineData("Maple spam in chat", "Maple", "spam in chat")]
    [InlineData("  Maple  ", "Maple", "")]
    [InlineData("\"Player 1", "Player 1", "")]
    public void A_target_is_one_word_or_a_quoted_name(string arg, string target, string tail)
    {
        var (t, r) = RconHostedService.SplitTarget(arg);
        t.Should().Be(target);
        r.Should().Be(tail);
    }

    [Theory]
    [InlineData(IdA, true, false)]
    [InlineData(Synth, false, true)]
    [InlineData("Player", false, false)]
    [InlineData("765611900", false, false)]
    [InlineData("00025a60dcf249c8899393a3f13e46b", false, false)]
    public void Id_shapes(string s, bool account, bool synthetic)
    {
        RconHostedService.IsAccountId(s).Should().Be(account);
        RconHostedService.IsSyntheticId(s).Should().Be(synthetic);
    }

    [Fact]
    public void Players_lists_every_player_with_the_id_even_when_names_repeat()
    {
        var text = RconHostedService.FormatPlayers(new[] { P(IdB, "Player 1"), P(IdA, "Player 1") }, 2);
        text.Should().StartWith("2 player(s) online:");
        text.Should().Contain("Player 1  " + IdA).And.Contain("Player 1  " + IdB);
        text.Should().NotContain("Phase 2");
    }

    [Fact]
    public void Players_with_no_roster_yet_reports_the_count_only()
    {
        RconHostedService.FormatPlayers(Array.Empty<PlayerSnapshot>(), 0).Should().Be("no players online");
        RconHostedService.FormatPlayers(Array.Empty<PlayerSnapshot>(), 3).Should().Be("3 player(s) online (names not available yet)");
    }

    [Fact]
    public void Help_names_kick_and_the_quoting_rule()
    {
        RconHostedService.HelpText.Should().Contain("kick <player|id>").And.Contain("quotes");
    }

    [Theory]
    [InlineData("kicked 1793204380", "kicked")]
    [InlineData("not-online 1793204380", "not-online")]
    [InlineData("joining: try again in a few seconds 1793204380", "joining: try again in a few seconds")]
    [InlineData("kicked", "kicked")]
    public void The_game_answer_drops_its_time(string tail, string result)
    {
        KickRequestFile.ParseResult(tail).Should().Be(result);
    }

    [Fact]
    public async Task Kick_request_round_trip_with_the_game_side()
    {
        var dir = Directory.CreateTempSubdirectory("sp-kick-").FullName;
        try
        {
            var game = Task.Run(async () =>
            {
                var req = Path.Combine(dir, "runtime.kick-request");
                for (var i = 0; i < 100 && !File.Exists(req); i++) await Task.Delay(20);
                var line = File.ReadAllText(req).Trim();
                File.Delete(req);
                var token = line.Split(' ')[0];
                line.Should().EndWith(" " + IdA);
                File.WriteAllText(Path.Combine(dir, "runtime.kick-done"), $"{token} kicked 1793204380\n");
            });
            var result = await KickRequestFile.AskAsync(dir, IdA, TimeSpan.FromSeconds(3));
            await game;
            result.Should().Be("kicked");
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task Kick_request_without_an_answer_times_out_and_takes_its_request_back()
    {
        var dir = Directory.CreateTempSubdirectory("sp-kick-").FullName;
        try
        {
            var result = await KickRequestFile.AskAsync(dir, IdA, TimeSpan.FromMilliseconds(600));
            result.Should().BeNull();
            File.Exists(Path.Combine(dir, "runtime.kick-request")).Should().BeFalse();
        }
        finally { Directory.Delete(dir, true); }
    }
}
