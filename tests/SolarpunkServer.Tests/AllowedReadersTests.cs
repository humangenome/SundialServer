using System.Net;
using SolarpunkServer.Configuration;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

// AllowedReaders limits who reaches the HTTP API at all. It lives in the supervisor because a
// machine that allows all inbound traffic, or a kernel HTTP listener the firewall cannot tell
// apart by program, leaves the port open to anyone.
public class AllowedReadersTests
{
    private static readonly string[] Web = { "198.51.100.7" };

    [Fact]
    public void NoListLetsEveryoneIn()
    {
        Assert.True(AdminRequestGate.ReaderAllowed(IPAddress.Parse("203.0.113.9"), null));
        Assert.True(AdminRequestGate.ReaderAllowed(IPAddress.Parse("203.0.113.9"), Array.Empty<string>()));
        Assert.Empty(new SolarpunkServerOptions().AllowedReaders);
    }

    [Fact]
    public void AListedAddressIsAllowedAndOthersAreNot()
    {
        Assert.True(AdminRequestGate.ReaderAllowed(IPAddress.Parse("198.51.100.7"), Web));
        Assert.False(AdminRequestGate.ReaderAllowed(IPAddress.Parse("198.51.100.8"), Web));
        Assert.False(AdminRequestGate.ReaderAllowed(IPAddress.Parse("203.0.113.9"), Web));
    }

    [Fact]
    public void LoopbackIsAlwaysAllowed()
    {
        Assert.True(AdminRequestGate.ReaderAllowed(IPAddress.Loopback, Web));
        Assert.True(AdminRequestGate.ReaderAllowed(IPAddress.IPv6Loopback, Web));
        Assert.True(AdminRequestGate.ReaderAllowed(IPAddress.Parse("127.0.0.2"), Web));
    }

    [Fact]
    public void AnIpv4MappedAddressReadsAsIpv4()
    {
        Assert.True(AdminRequestGate.ReaderAllowed(IPAddress.Parse("::ffff:198.51.100.7"), Web));
        Assert.True(AdminRequestGate.ReaderAllowed(IPAddress.Parse("198.51.100.7"), new[] { "::ffff:198.51.100.7" }));
        Assert.False(AdminRequestGate.ReaderAllowed(IPAddress.Parse("::ffff:203.0.113.9"), Web));
    }

    [Fact]
    public void AnUnknownCallerAndJunkEntriesAreRefused()
    {
        Assert.False(AdminRequestGate.ReaderAllowed(null, Web));
        Assert.False(AdminRequestGate.ReaderAllowed(IPAddress.Parse("203.0.113.9"), new[] { "not an address", " ", "" }));
        Assert.True(AdminRequestGate.ReaderAllowed(IPAddress.Parse("198.51.100.7"), new[] { "junk", " 198.51.100.7 " }));
    }
}
