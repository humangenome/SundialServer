using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using FluentAssertions;
using Xunit;
using Solarpunk.Rcon;

namespace SolarpunkServer.Tests;

// The RCON listener on the wire: the login, what an empty password means, and that a connection
// which never logs in does not keep its slot. These run on loopback, which the per-address limits
// never apply to (SourceGuardTests covers those rules).
public sealed class RconServerTests
{
    [Fact]
    public async Task With_no_password_set_nobody_gets_in()
    {
        using var server = new RconServer(0, "", _ => Task.FromResult("ran"));
        server.Start(CancellationToken.None);
        try
        {
            using var client = new TcpClient();
            await client.ConnectAsync("127.0.0.1", server.BoundPort);
            var stream = client.GetStream();
            await WritePacketAsync(stream, 7, 2, "status");
            var resp = await ReadPacketAsync(stream);
            resp.Should().NotBeNull();
            resp!.Value.id.Should().Be(-1, "a command before a login is refused");

            using var second = new TcpClient();
            await second.ConnectAsync("127.0.0.1", server.BoundPort);
            var s2 = second.GetStream();
            await WritePacketAsync(s2, 1, 3, "");
            await ReadPacketAsync(s2);
            var auth = await ReadPacketAsync(s2);
            auth!.Value.id.Should().Be(-1, "an empty password is not a login");
        }
        finally
        {
            await server.StopAsync();
        }
    }

    [Fact]
    public async Task Login_then_command_round_trips()
    {
        using var server = new RconServer(0, "secret", cmd => Task.FromResult(cmd == "status" ? "ok" : "?"));
        server.Start(CancellationToken.None);
        try
        {
            using var client = new TcpClient();
            await client.ConnectAsync("127.0.0.1", server.BoundPort);
            var stream = client.GetStream();
            await WritePacketAsync(stream, 1, 3, "secret");
            (await ReadPacketAsync(stream))!.Value.type.Should().Be(0);
            var auth = await ReadPacketAsync(stream);
            auth!.Value.type.Should().Be(2);
            auth.Value.id.Should().Be(1, "a good password answers with the request id");

            await WritePacketAsync(stream, 7, 2, "status");
            var resp = await ReadPacketAsync(stream);
            resp!.Value.id.Should().Be(7);
            resp.Value.body.Should().Be("ok");
        }
        finally
        {
            await server.StopAsync();
        }
    }

    [Fact]
    public async Task A_wrong_password_answers_minus_one_and_closes()
    {
        using var server = new RconServer(0, "secret", _ => Task.FromResult(""));
        server.Start(CancellationToken.None);
        try
        {
            using var client = new TcpClient();
            await client.ConnectAsync("127.0.0.1", server.BoundPort);
            var stream = client.GetStream();
            await WritePacketAsync(stream, 1, 3, "secreT");
            await ReadPacketAsync(stream);
            var auth = await ReadPacketAsync(stream);
            auth!.Value.id.Should().Be(-1);
            (await ReadPacketAsync(stream)).Should().BeNull("the server closes the connection after a failed login");
        }
        finally
        {
            await server.StopAsync();
        }
    }

    [Fact]
    public async Task A_connection_that_never_logs_in_is_closed()
    {
        using var server = new RconServer(0, "secret", _ => Task.FromResult(""));
        server.Start(CancellationToken.None);
        try
        {
            using var client = new TcpClient();
            await client.ConnectAsync("127.0.0.1", server.BoundPort);
            var stream = client.GetStream();
            // Half a packet, then silence: the old listener waited on it forever.
            await stream.WriteAsync(new byte[] { 20, 0 });
            var buf = new byte[16];
            using var giveUp = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            var n = await stream.ReadAsync(buf, giveUp.Token);
            n.Should().Be(0, "the server drops a connection that has not logged in after 10 s");
        }
        finally
        {
            await server.StopAsync();
        }
    }

    [Fact]
    public async Task A_logged_in_console_may_stay_quiet_past_the_login_deadline()
    {
        using var server = new RconServer(0, "secret", _ => Task.FromResult("pong"));
        server.Start(CancellationToken.None);
        try
        {
            using var client = new TcpClient();
            await client.ConnectAsync("127.0.0.1", server.BoundPort);
            var stream = client.GetStream();
            await WritePacketAsync(stream, 1, 3, "secret");
            await ReadPacketAsync(stream);
            (await ReadPacketAsync(stream))!.Value.id.Should().Be(1);

            await Task.Delay(TimeSpan.FromSeconds(12));
            await WritePacketAsync(stream, 2, 2, "ping");
            var resp = await ReadPacketAsync(stream);
            resp.Should().NotBeNull("the login deadline applies only before the login");
            resp!.Value.body.Should().Be("pong");
        }
        finally
        {
            await server.StopAsync();
        }
    }

    private static async Task WritePacketAsync(NetworkStream s, int id, int type, string body)
    {
        var bodyBytes = Encoding.UTF8.GetBytes(body);
        var size = 4 + 4 + bodyBytes.Length + 2;
        var buf = new byte[4 + size];
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(0, 4), size);
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(4, 4), id);
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(8, 4), type);
        Buffer.BlockCopy(bodyBytes, 0, buf, 12, bodyBytes.Length);
        await s.WriteAsync(buf);
        await s.FlushAsync();
    }

    private static async Task<(int id, int type, string body)?> ReadPacketAsync(NetworkStream s)
    {
        using var giveUp = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var sizeBuf = new byte[4];
        if (!await ReadExactAsync(s, sizeBuf, giveUp.Token)) return null;
        var size = BinaryPrimitives.ReadInt32LittleEndian(sizeBuf);
        var rest = new byte[size];
        if (!await ReadExactAsync(s, rest, giveUp.Token)) return null;
        var id = BinaryPrimitives.ReadInt32LittleEndian(rest.AsSpan(0, 4));
        var type = BinaryPrimitives.ReadInt32LittleEndian(rest.AsSpan(4, 4));
        var bodyEnd = Array.IndexOf<byte>(rest, 0, 8);
        if (bodyEnd < 0) bodyEnd = rest.Length - 1;
        return (id, type, Encoding.UTF8.GetString(rest, 8, bodyEnd - 8));
    }

    private static async Task<bool> ReadExactAsync(NetworkStream s, byte[] buf, CancellationToken ct)
    {
        var read = 0;
        try
        {
            while (read < buf.Length)
            {
                var n = await s.ReadAsync(buf.AsMemory(read), ct);
                if (n == 0) return false;
                read += n;
            }
        }
        catch (IOException) { return false; }
        return true;
    }
}
