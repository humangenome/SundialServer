using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using FluentAssertions;
using Xunit;
using Solarpunk.SourceQuery;

namespace SolarpunkServer.Tests;

// The A2S responder's receive loop must outlive a socket error. On Windows, a reply sent to a port
// that has closed (a scanner, or a browser that gave up) makes the NEXT receive on the server's socket
// throw "connection reset". That used to end the loop for good: the server stopped answering
// server-list queries until the server restarted, with nothing logged. On Linux the receive does
// not throw, so this test only bites on the Windows CI runner.
public sealed class SourceQueryLoopTests
{
    private static byte[] ChallengeRequest()
    {
        var q = new byte[9];
        BinaryPrimitives.WriteInt32LittleEndian(q, -1);
        q[4] = 0x55; // A2S_PLAYER with challenge -1 asks for a challenge number
        BinaryPrimitives.WriteInt32LittleEndian(q.AsSpan(5), -1);
        return q;
    }

    [Fact]
    public async Task Replies_to_closed_ports_do_not_stop_the_responder()
    {
        using var server = new SourceQueryServer(0, () => default,
            () => Array.Empty<PlayerInfoEntry>(), () => Array.Empty<KeyValuePair<string, string>>());
        await server.StartAsync(CancellationToken.None);
        try
        {
            var target = new IPEndPoint(IPAddress.Loopback, server.BoundPort);

            // Ask from sockets that close at once, so the server's replies land on closed ports.
            for (var i = 0; i < 40; i++)
            {
                using var gone = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
                gone.Send(ChallengeRequest(), 9, target);
            }
            await Task.Delay(300);

            using var asker = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
            byte[]? reply = null;
            for (var attempt = 0; attempt < 5 && reply is null; attempt++)
            {
                await asker.SendAsync(ChallengeRequest(), 9, target);
                using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                try { reply = (await asker.ReceiveAsync(wait.Token)).Buffer; }
                catch (OperationCanceledException) { }
            }

            reply.Should().NotBeNull("the responder must still answer after replies to closed ports");
            reply![4].Should().Be(0x41, "a challenge reply starts with 'A'");
        }
        finally
        {
            await server.StopAsync();
        }
    }
}
