using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using FluentAssertions;
using Xunit;
using Solarpunk.Rcon;
using Microsoft.Extensions.Logging;

namespace SolarpunkServer.Tests;

// RCON's wrong-password limit on the wire, from a real non-loopback address: five wrong passwords turn
// the address away (even with the right password next), loopback stays open, and the block is logged
// once, at warning level, with the address, the door and the length and without any password.
[Collection("SourceGuard")]
public sealed class RconLockoutTests : IDisposable
{
    public RconLockoutTests() => TestNet.ResetGuard();
    public void Dispose() => TestNet.ResetGuard();

    [Fact]
    public async Task Five_wrong_passwords_turn_the_address_away_and_log_one_block_line()
    {
        var own = TestNet.OwnAddress();
        var log = new ListLogger<RconServer>();
        using var server = new RconServer(0, "right-pass", _ => Task.FromResult("pong"), log);
        server.Start(CancellationToken.None);
        try
        {
            for (var i = 0; i < 5; i++)
                (await LoginAsync(own, server.BoundPort, "wrong-" + i)).Should().Be(-1);

            (await LoginAsync(own, server.BoundPort, "right-pass"))
                .Should().BeNull("the address is turned away for a minute, even with the right password");
            (await LoginAsync(IPAddress.Loopback, server.BoundPort, "right-pass"))
                .Should().Be(1, "loopback is never limited");

            var blocks = log.Entries.Where(e => e.Text.Contains("auth block")).ToList();
            blocks.Should().ContainSingle("one line per block, not one per wrong try");
            blocks[0].Level.Should().Be(LogLevel.Warning);
            blocks[0].Text.Should().Contain("door=rcon").And.Contain("address=" + own).And.Contain("blocked=60s");
            blocks[0].Text.Should().NotContain("wrong-").And.NotContain("right-pass");
        }
        finally
        {
            await server.StopAsync();
        }
    }

    // The id of the login reply (request id = success, -1 = refused), or null when the server closed
    // the connection without answering.
    private static async Task<int?> LoginAsync(IPAddress host, int port, string password)
    {
        using var client = new TcpClient();
        await client.ConnectAsync(host, port);
        var s = client.GetStream();
        try
        {
            var body = Encoding.UTF8.GetBytes(password);
            var size = 4 + 4 + body.Length + 2;
            var buf = new byte[4 + size];
            BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(0, 4), size);
            BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(4, 4), 1);
            BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(8, 4), 3);
            Buffer.BlockCopy(body, 0, buf, 12, body.Length);
            await s.WriteAsync(buf);
            if (await ReadIdAsync(s) is null) return null; // the empty type-0 packet
            return await ReadIdAsync(s);
        }
        catch (IOException) { return null; }
        catch (SocketException) { return null; }
    }

    private static async Task<int?> ReadIdAsync(NetworkStream s)
    {
        using var giveUp = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var head = new byte[12];
        var read = 0;
        while (read < head.Length)
        {
            var n = await s.ReadAsync(head.AsMemory(read), giveUp.Token);
            if (n == 0) return null;
            read += n;
        }
        var size = BinaryPrimitives.ReadInt32LittleEndian(head.AsSpan(0, 4));
        var rest = new byte[size - 8];
        read = 0;
        while (read < rest.Length)
        {
            var n = await s.ReadAsync(rest.AsMemory(read), giveUp.Token);
            if (n == 0) return null;
            read += n;
        }
        return BinaryPrimitives.ReadInt32LittleEndian(head.AsSpan(4, 4));
    }
}
