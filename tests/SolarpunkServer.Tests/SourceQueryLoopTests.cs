using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using FluentAssertions;
using Solarpunk.SourceQuery;
using Xunit;
using Xunit.Abstractions;

namespace SolarpunkServer.Tests;

// The A2S responder must keep answering after its replies land on closed ports (a scanner, or a
// player's app that gave up and closed its socket). On Windows each such reply comes back as a
// "connection reset" error on a later receive. That once ended the receive loop for good (the server
// stopped answering server-list queries until the supervisor restarted, with nothing logged), and
// later paused it 50 ms per error, so a burst of them kept real queries waiting for seconds.
// Linux never reports them on a receive, so the error path only runs on the Windows CI runner.
//
// No fixed sleeps: each step waits for the thing it needs (the server has handled every ask, the
// first report has reached it) with a deadline far past any slow runner, so these pass or fail on
// what the responder does, not on how busy the machine is.
public sealed class SourceQueryLoopTests
{
    private const int ClosedPortAsks = 40;
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(30);

    private readonly ITestOutputHelper _out;

    public SourceQueryLoopTests(ITestOutputHelper output) => _out = output;

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
        var reports = await AnswersAfterClosedPortRepliesAsync(ignoreClosedPortReports: true);

        // The server switches Windows' closed-port reports off, so none reach its receive loop.
        reports.Should().Be(0, "the responder turns the closed-port reports off on Windows, and Linux never sends them");
    }

    [Fact]
    public async Task The_responder_outlives_closed_port_reports_that_reach_it()
    {
        var reports = await AnswersAfterClosedPortRepliesAsync(ignoreClosedPortReports: false);

        if (OperatingSystem.IsWindows())
            reports.Should().BeGreaterThan(0, "with the reports left on, Windows reports the replies to closed ports");
    }

    // Returns how many closed-port reports the server's receive loop met.
    private async Task<int> AnswersAfterClosedPortRepliesAsync(bool ignoreClosedPortReports)
    {
        var handled = 0;
        var allHandled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var server = new SourceQueryServer(0, () => default,
            () => Array.Empty<PlayerInfoEntry>(), () => Array.Empty<KeyValuePair<string, string>>(),
            availabilityProvider: null,
            queryObserver: (_, _) =>
            {
                if (Interlocked.Increment(ref handled) == ClosedPortAsks) allHandled.TrySetResult();
            },
            ignoreClosedPortReports: ignoreClosedPortReports,
            // All 40 asks come from 127.0.0.1; a budget far above them keeps this test about closed ports
            // only (SourceQueryChallengeTests covers the per-address limit).
            limits: new ReplyLimits(Burst: 1000, PerSecond: 1000, MaxTrackedAddresses: 8192));
        await server.StartAsync(CancellationToken.None);
        try
        {
            var target = new IPEndPoint(IPAddress.Loopback, server.BoundPort);
            var clock = Stopwatch.StartNew();

            // Ask from sockets that close at once, so the server's replies land on closed ports.
            for (var i = 0; i < ClosedPortAsks; i++)
            {
                using var gone = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
                gone.Send(ChallengeRequest(), 9, target);
            }

            var finished = await Task.WhenAny(allHandled.Task, Task.Delay(Deadline));
            finished.Should().BeSameAs(allHandled.Task,
                "the server must answer all {0} asks (it handled {1})", ClosedPortAsks, Volatile.Read(ref handled));
            var handledMs = clock.ElapsedMilliseconds;

            if (!ignoreClosedPortReports && OperatingSystem.IsWindows())
            {
                // Make sure the error path has really run before the real query goes in.
                while (server.ClosedPortReports == 0 && clock.Elapsed < Deadline)
                    await Task.Delay(10);
                server.ClosedPortReports.Should().BeGreaterThan(0, "Windows reports a reply to a closed port");
            }

            // A real asker that stays open: ask, and ask again each second until the deadline. A reply
            // to an earlier ask still counts, because this socket never closes.
            using var asker = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
            var askedAt = clock.ElapsedMilliseconds;
            byte[]? reply = null;
            var asks = 0;
            while (reply is null && clock.Elapsed < Deadline + Deadline)
            {
                await asker.SendAsync(ChallengeRequest(), 9, target);
                asks++;
                using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                try { reply = (await asker.ReceiveAsync(wait.Token)).Buffer; }
                catch (OperationCanceledException) { }
            }

            _out.WriteLine($"reports left on: {!ignoreClosedPortReports}; {ClosedPortAsks} asks handled after {handledMs} ms; " +
                $"closed-port reports seen: {server.ClosedPortReports}; real query answered {clock.ElapsedMilliseconds - askedAt} ms " +
                $"after it was first sent ({asks} send(s))");

            reply.Should().NotBeNull("the responder must still answer after replies to closed ports");
            reply![4].Should().Be(0x41, "a challenge reply starts with 'A'");
            return server.ClosedPortReports;
        }
        finally
        {
            await server.StopAsync();
        }
    }
}
