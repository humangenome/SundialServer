using FluentAssertions;
using SolarpunkServer.Configuration;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// On an "eos" server players join with the game's invite code and cannot send the
/// SolarpunkAuth name-channel token, so the password is not enforced there. The
/// watchdog and Source query key off <see cref="SolarpunkServerOptions.PasswordGateEnforced"/>;
/// if it said true on eos, the watchdog would fail-close a server whose gate correctly
/// reports no password.
/// </summary>
public class PasswordGateTests
{
    private static SolarpunkServerOptions Opts(string password, string transport) =>
        new() { SolarpunkAuthPassword = password, Transport = transport };

    [Theory]
    [InlineData("hunter2", "ip", true)]
    [InlineData("hunter2", "", true)]
    [InlineData("hunter2", "eos", false)]
    [InlineData("hunter2", "EOS", false)]
    [InlineData("", "ip", false)]
    [InlineData("", "eos", false)]
    public void Enforced_only_with_a_password_on_the_address_transport(string password, string transport, bool expected)
        => Opts(password, transport).PasswordGateEnforced.Should().Be(expected);

    [Fact]
    public void Default_transport_is_the_address_join()
    {
        var o = new SolarpunkServerOptions { SolarpunkAuthPassword = "hunter2" };
        o.Transport.Should().Be("ip");
        o.PasswordGateEnforced.Should().BeTrue();
    }
}
