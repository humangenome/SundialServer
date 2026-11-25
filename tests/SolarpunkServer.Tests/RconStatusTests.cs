using FluentAssertions;
using Solarpunk.Protocol;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// The RCON <c>status</c> line. Invite-code servers (Transport "eos") never load the in-game plugin, so the
/// line leaves the plugin field out there instead of reading "plugin=disconnected" on every healthy server.
/// Join-by-IP servers keep the field (Ryan 2026-11-25, question 48).
/// </summary>
public class RconStatusTests
{
    private static PipeConnection Plugin() =>
        new("sp-225629", 4321, "0.1.104", new FrameCodec(new byte[32]), (_, _) => Task.CompletedTask);

    [Theory]
    [InlineData("eos")]
    [InlineData("EOS")]
    public void An_invite_code_server_leaves_the_plugin_field_out(string transport)
    {
        RconHostedService.FormatStatus("sp-225629", transport, null, 0)
            .Should().Be("instance=sp-225629 players=0");
    }

    [Theory]
    [InlineData("ip")]
    [InlineData("")]
    public void A_join_by_ip_server_keeps_the_plugin_field(string transport)
    {
        RconHostedService.FormatStatus("sp-225629", transport, null, 2)
            .Should().Be("instance=sp-225629 plugin=disconnected players=2");
    }

    [Theory]
    [InlineData("ip")]
    [InlineData("eos")]
    public void A_connected_plugin_is_always_shown(string transport)
    {
        RconHostedService.FormatStatus("sp-225629", transport, Plugin(), 1)
            .Should().Be("instance=sp-225629 plugin=connected pid=4321 version=0.1.104 players=1");
    }
}
