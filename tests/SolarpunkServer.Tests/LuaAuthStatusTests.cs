using FluentAssertions;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// The fail-closed gate for a passworded server. Every one of these asserts the
/// safe direction: unless the in-game password gate is proving itself ready and
/// recent, the watchdog must not treat the server as protected.
/// </summary>
public class LuaAuthStatusTests
{
    private static readonly TimeSpan Window = TimeSpan.FromSeconds(90);
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    private static string[] StatusFile(long updated, string ready = "1", string pw = "1", string reason = "gate_active")
        => new[] { $"ready={ready}", $"passwordConfigured={pw}", $"updated={updated}", $"reason={reason}" };

    [Fact]
    public void Parse_reads_every_field()
    {
        var s = LuaAuthStatus.Parse(StatusFile(Now.ToUnixTimeSeconds()));

        s.Exists.Should().BeTrue();
        s.Ready.Should().BeTrue();
        s.PasswordConfigured.Should().BeTrue();
        s.Reason.Should().Be("gate_active");
        s.UpdatedAt.Should().Be(Now);
    }

    [Fact]
    public void Parse_tolerates_blank_lines_unknown_keys_and_padding()
    {
        var s = LuaAuthStatus.Parse(new[]
        {
            "",
            "  ready = 1  ",
            "somethingNew=whatever",
            "passwordConfigured=1",
            $"updated = {Now.ToUnixTimeSeconds()} ",
            "=novalue",
            "reason=gate_active",
        });

        s.Ready.Should().BeTrue();
        s.PasswordConfigured.Should().BeTrue();
        s.UpdatedAt.Should().Be(Now);
        s.IsGateReady(Window, Now).Should().BeTrue();
    }

    [Fact]
    public void Parse_treats_a_non_numeric_updated_as_no_stamp()
    {
        var s = LuaAuthStatus.Parse(new[] { "ready=1", "passwordConfigured=1", "updated=notanumber" });

        s.UpdatedAt.Should().BeNull();
        s.IsGateReady(Window, Now).Should().BeFalse();
    }

    [Fact]
    public void Missing_file_is_never_ready()
    {
        LuaAuthStatus.Missing.Exists.Should().BeFalse();
        LuaAuthStatus.Missing.IsGateReady(Window, Now).Should().BeFalse();
    }

    [Fact]
    public void Read_error_is_never_ready()
    {
        LuaAuthStatus.ReadError.IsGateReady(Window, Now).Should().BeFalse();
        LuaAuthStatus.ReadError.Reason.Should().Be("read_error");
    }

    // This is the regression the 0.1.68 sync carried: a status file with no
    // "updated" key parsed as ready, so a file left behind by a dead game
    // process kept the gate open forever.
    [Fact]
    public void Status_without_an_updated_stamp_is_not_fresh()
    {
        var s = LuaAuthStatus.Parse(new[] { "ready=1", "passwordConfigured=1", "reason=gate_active" });

        s.Ready.Should().BeTrue();
        s.IsFresh(Window, Now).Should().BeFalse();
        s.IsGateReady(Window, Now).Should().BeFalse();
    }

    [Theory]
    [InlineData(0, true)]     // stamped this second
    [InlineData(-45, true)]   // mid-window
    [InlineData(-90, true)]   // exactly the boundary is still fresh
    [InlineData(-91, false)]  // one second past the boundary is stale
    [InlineData(-3600, false)]
    public void Freshness_follows_the_window(int ageSeconds, bool expected)
    {
        var s = LuaAuthStatus.Parse(StatusFile(Now.AddSeconds(ageSeconds).ToUnixTimeSeconds()));

        s.IsFresh(Window, Now).Should().Be(expected);
        s.IsGateReady(Window, Now).Should().Be(expected);
    }

    // A clock-skewed or hand-edited file must not be able to buy itself an
    // unbounded amount of validity by stamping the future.
    [Fact]
    public void A_future_stamp_is_not_fresh()
    {
        var s = LuaAuthStatus.Parse(StatusFile(Now.AddSeconds(120).ToUnixTimeSeconds()));

        s.IsFresh(Window, Now).Should().BeFalse();
        s.IsGateReady(Window, Now).Should().BeFalse();
    }

    [Fact]
    public void Ready_zero_is_not_a_ready_gate_even_when_fresh()
    {
        var s = LuaAuthStatus.Parse(StatusFile(Now.ToUnixTimeSeconds(), ready: "0", reason: "runtime_init"));

        s.IsFresh(Window, Now).Should().BeTrue();
        s.IsGateReady(Window, Now).Should().BeFalse();
    }

    [Fact]
    public void Password_not_configured_is_not_a_ready_gate()
    {
        var s = LuaAuthStatus.Parse(StatusFile(Now.ToUnixTimeSeconds(), pw: "0", reason: "no_password_configured"));

        s.IsGateReady(Window, Now).Should().BeFalse();
    }

    [Theory]
    [InlineData("true")]
    [InlineData("yes")]
    [InlineData("01")]
    [InlineData("")]
    public void Only_the_literal_one_counts_as_ready(string value)
    {
        var s = LuaAuthStatus.Parse(new[] { $"ready={value}", "passwordConfigured=1", $"updated={Now.ToUnixTimeSeconds()}" });

        s.Ready.Should().BeFalse();
        s.IsGateReady(Window, Now).Should().BeFalse();
    }
}
