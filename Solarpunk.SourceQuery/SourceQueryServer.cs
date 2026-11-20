using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Solarpunk.SourceQuery;

/// <summary>
/// Source A2S query responder. Implements the subset of the Source query
/// protocol GameTracker, ServerMonkey, BattleMetrics, and stock browsers rely on:
/// A2S_INFO, A2S_PLAYER, A2S_RULES, all gated by the standard challenge-response
/// anti-spoof handshake (A2S_INFO too, as Valve's own servers have done since 2020).
///
/// A request without a valid challenge only ever gets the 9-byte challenge reply, which is
/// smaller than the request, so a forged sender address cannot turn the server into an
/// amplifier. Challenges are worked out from the asker's address and the time (a keyed
/// hash), so nothing is stored per asker. On top of that each address gets a small reply
/// budget (<see cref="ReplyLimits"/>); past it, queries from that address are dropped
/// until the budget refills.
///
/// Spec: https://developer.valvesoftware.com/wiki/Server_queries
/// </summary>
public sealed class SourceQueryServer : IDisposable
{
    private readonly UdpClient _udp;
    private readonly Func<ServerInfoSnapshot> _infoProvider;
    private readonly Func<IReadOnlyList<PlayerInfoEntry>> _playerProvider;
    private readonly Func<IReadOnlyList<KeyValuePair<string, string>>> _rulesProvider;
    private readonly Func<bool> _availabilityProvider;
    private readonly Action<string, string>? _queryObserver;
    private readonly Action<string>? _notice;
    private readonly byte[] _challengeKey = RandomNumberGenerator.GetBytes(32);
    private readonly Func<long> _nowMs;
    private readonly ReplyLimits _limits;
    private readonly Dictionary<IPAddress, ReplyBudget> _budgets = new();
    private long _lastSweepMs = long.MinValue;
    private long _lastIdleSweepMs = long.MinValue;
    private long _noticeWindowStartMs = long.MinValue;
    private int _refusedThisWindow;
    private long _repliesRefused;
    private CancellationTokenSource? _cts;
    private Task? _loop;
    private int _closedPortReports;

    // Windows turns an ICMP "port unreachable" for an earlier reply into a "connection reset" error on
    // a later receive (SIO_UDP_CONNRESET), and a TTL-expired one into "network reset" (SIO_UDP_NETRESET).
    // A query responder has no connection to reset, so both reports are switched off: a reply that lands
    // on a closed port is simply lost, as it is on Linux.
    private const int SioUdpConnReset = unchecked((int)0x9800000C);
    private const int SioUdpNetReset = unchecked((int)0x9800000F);

    // <param name="queryObserver">Optional diagnostic callback invoked for every
    // recognized A2S query as (queryType, remoteEndpoint). Pure logging hook —
    // does not affect the reply. Exceptions thrown by the observer are swallowed
    // so a logging fault can never break the responder.</param>
    // <param name="notice">Optional callback for one plain line, at most once a minute, saying how many
    // queries were dropped over the per-address reply budget since the last such line.</param>
    public SourceQueryServer(
        int port,
        Func<ServerInfoSnapshot> infoProvider,
        Func<IReadOnlyList<PlayerInfoEntry>> playerProvider,
        Func<IReadOnlyList<KeyValuePair<string, string>>> rulesProvider,
        Func<bool>? availabilityProvider = null,
        Action<string, string>? queryObserver = null,
        Action<string>? notice = null)
        : this(port, infoProvider, playerProvider, rulesProvider, availabilityProvider, queryObserver,
            ignoreClosedPortReports: true, notice: notice)
    {
    }

    // ignoreClosedPortReports=false leaves Windows' reports on, so a test can prove the receive loop
    // outlives them too. limits and nowMs let a test use a small budget and its own clock.
    internal SourceQueryServer(
        int port,
        Func<ServerInfoSnapshot> infoProvider,
        Func<IReadOnlyList<PlayerInfoEntry>> playerProvider,
        Func<IReadOnlyList<KeyValuePair<string, string>>> rulesProvider,
        Func<bool>? availabilityProvider,
        Action<string, string>? queryObserver,
        bool ignoreClosedPortReports,
        Action<string>? notice = null,
        ReplyLimits? limits = null,
        Func<long>? nowMs = null)
    {
        _udp = new UdpClient(port);
        if (ignoreClosedPortReports && OperatingSystem.IsWindows())
        {
            // Never fatal: if a Windows build refuses either one, the receive loop below still goes
            // straight on past each report.
            try { _udp.Client.IOControl(SioUdpConnReset, new byte[4], null); } catch (Exception) { }
            try { _udp.Client.IOControl(SioUdpNetReset, new byte[4], null); } catch (Exception) { }
        }
        _infoProvider = infoProvider;
        _playerProvider = playerProvider;
        _rulesProvider = rulesProvider;
        _availabilityProvider = availabilityProvider ?? (() => true);
        _queryObserver = queryObserver;
        _notice = notice;
        _limits = limits ?? ReplyLimits.Default;
        _nowMs = nowMs ?? (() => Environment.TickCount64);
    }

    public int BoundPort => ((IPEndPoint)_udp.Client.LocalEndPoint!).Port;

    // How many receives ended in a closed-port or TTL report. Stays 0 on Windows while the reports
    // are switched off, and on Linux, which never reports them on a receive.
    internal int ClosedPortReports => Volatile.Read(ref _closedPortReports);

    // Queries dropped over the per-address reply budget since the server started.
    internal long RepliesRefused => Interlocked.Read(ref _repliesRefused);

    // Addresses with a reply budget being tracked right now.
    internal int TrackedAddresses => _budgets.Count;

    public Task StartAsync(CancellationToken ct)
    {
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _loop = Task.Run(() => LoopAsync(_cts.Token), _cts.Token);
        return Task.CompletedTask;
    }

    public async Task StopAsync()
    {
        _cts?.Cancel();
        try { if (_loop is not null) await _loop.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        _udp.Dispose();
    }

    public void Dispose()
    {
        _cts?.Cancel();
        _udp.Dispose();
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            UdpReceiveResult res;
            try { res = await _udp.ReceiveAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException ex) when (ex.SocketErrorCode is SocketError.ConnectionReset or SocketError.NetworkReset)
            {
                // A report that an earlier reply landed on a closed port (Windows, where switching the
                // reports off failed or was not asked for). The socket is fine and the next query may
                // already be waiting, so go straight on. This used to end the loop for good, and later
                // paused it 50 ms per report, so a burst of them kept real queries waiting for seconds.
                Interlocked.Increment(ref _closedPortReports);
                continue;
            }
            catch (SocketException)
            {
                // Any other receive error: a short pause so an error that repeats cannot spin the
                // processor, then carry on answering.
                try { await Task.Delay(50, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                continue;
            }

            try
            {
                var reply = HandleQuery(res.RemoteEndPoint, res.Buffer);
                if (reply is not null && reply.Length > 0)
                    await _udp.SendAsync(reply, reply.Length, res.RemoteEndPoint).ConfigureAwait(false);
            }
            catch
            {
                // Malformed UDP query — drop silently.
            }
        }
    }

    // The A2S_INFO request body: "Source Engine Query" and its terminating zero.
    private static readonly byte[] InfoRequestBody = Encoding.ASCII.GetBytes("Source Engine Query\0");

    internal byte[]? HandleQuery(IPEndPoint from, byte[] payload)
    {
        if (payload.Length < 5) return null;
        var marker = BinaryPrimitives.ReadInt32LittleEndian(payload);
        if (marker != -1) return null;
        var header = payload[4];

        string queryType;
        int? challenge;
        switch (header)
        {
            case 0x54:
                // FF FF FF FF 'T' "Source Engine Query\0" [challenge]: the challenge is optional on the
                // first ask; a client resends with the one it was given.
                if (payload.Length < 5 + InfoRequestBody.Length
                    || !payload.AsSpan(5, InfoRequestBody.Length).SequenceEqual(InfoRequestBody))
                    return null;
                queryType = "A2S_INFO";
                var at = 5 + InfoRequestBody.Length;
                challenge = payload.Length >= at + 4 ? BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(at, 4)) : null;
                break;
            case 0x55:
            case 0x56:
                if (payload.Length < 9) return null;
                queryType = header == 0x55 ? "A2S_PLAYER" : "A2S_RULES";
                challenge = BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(5, 4));
                break;
            default:
                return null;
        }

        NotifyObserver(queryType, from);
        var address = from.Address.IsIPv4MappedToIPv6 ? from.Address.MapToIPv4() : from.Address;
        if (!TakeReplyBudget(address)) return null;

        // No valid challenge: the 9-byte challenge reply, and nothing else is looked at (so a flood of
        // forged asks never reaches the game-process check below).
        if (challenge is not { } c || c == -1 || !ChallengeIsValid(address, c))
            return BuildChallengeReply(address);

        if (!_availabilityProvider()) return null;
        return header switch
        {
            0x54 => BuildInfoReply(),
            0x55 => BuildPlayerOrRulesReply(isRules: false),
            _ => BuildPlayerOrRulesReply(isRules: true),
        };
    }

    // A challenge lives for one to two windows of this length, then the asker is simply given a new one.
    private const long ChallengeWindowMs = 30_000;

    internal int ChallengeFor(IPAddress address, long window)
    {
        Span<byte> input = stackalloc byte[24];
        if (!address.TryWriteBytes(input, out var written)) written = 0;
        BinaryPrimitives.WriteInt64LittleEndian(input.Slice(16), window);
        Span<byte> mac = stackalloc byte[32];
        HMACSHA256.HashData(_challengeKey, input, mac);
        var value = BinaryPrimitives.ReadInt32LittleEndian(mac);
        // -1 means "send me a challenge" in a request, so it is never handed out as one.
        return value == -1 ? int.MaxValue : value;
    }

    private long CurrentWindow() => _nowMs() / ChallengeWindowMs;

    private bool ChallengeIsValid(IPAddress address, int challenge)
    {
        var window = CurrentWindow();
        return challenge == ChallengeFor(address, window) || challenge == ChallengeFor(address, window - 1);
    }

    private byte[] BuildChallengeReply(IPAddress address)
    {
        var reply = new byte[9];
        BinaryPrimitives.WriteInt32LittleEndian(reply, -1);
        reply[4] = 0x41;                              // A = challenge
        BinaryPrimitives.WriteInt32LittleEndian(reply.AsSpan(5), ChallengeFor(address, CurrentWindow()));
        return reply;
    }

    // Every 10 seconds of traffic, addresses whose budget has refilled (quiet for Burst / PerSecond seconds,
    // 4 s by default) are dropped, so the table only holds addresses that asked in the last few seconds.
    private const long IdleSweepIntervalMs = 10_000;

    // Each address may have Burst replies at once, refilled at PerSecond. The table never holds more than
    // MaxTrackedAddresses: quiet addresses are dropped on the 10-second sweep and again whenever the table
    // is full, and when it is full of busy addresses (thousands of different senders inside a few seconds
    // is a flood, not players) a NEW address is refused, never added. Addresses already in the table keep
    // their budget through a flood.
    private bool TakeReplyBudget(IPAddress address)
    {
        var now = _nowMs();
        if (_lastIdleSweepMs == long.MinValue) _lastIdleSweepMs = now;
        else if (now - _lastIdleSweepMs >= IdleSweepIntervalMs)
        {
            _lastIdleSweepMs = now;
            RemoveRefilledBudgets(now);
        }
        if (!_budgets.TryGetValue(address, out var budget))
        {
            if (_budgets.Count >= _limits.MaxTrackedAddresses) SweepRefilledBudgets(now);
            if (_budgets.Count >= _limits.MaxTrackedAddresses) return Refuse(now);
            budget = new ReplyBudget { Tokens = _limits.Burst, LastMs = now };
            _budgets[address] = budget;
        }

        var elapsed = Math.Max(0, now - budget.LastMs);
        budget.Tokens = Math.Min(_limits.Burst, budget.Tokens + elapsed * _limits.PerSecond / 1000.0);
        budget.LastMs = now;
        if (budget.Tokens < 1) return Refuse(now);
        budget.Tokens -= 1;
        return true;
    }

    private void SweepRefilledBudgets(long now)
    {
        // At most four sweeps a second, so a flood cannot make every new sender pay for a full walk.
        if (_lastSweepMs != long.MinValue && now - _lastSweepMs < 250) return;
        _lastSweepMs = now;
        RemoveRefilledBudgets(now);
    }

    private void RemoveRefilledBudgets(long now)
    {
        var refillMs = (long)Math.Ceiling(_limits.Burst * 1000.0 / _limits.PerSecond);
        List<IPAddress>? idle = null;
        foreach (var (address, budget) in _budgets)
        {
            if (now - budget.LastMs >= refillMs) (idle ??= new List<IPAddress>()).Add(address);
        }
        if (idle is null) return;
        foreach (var address in idle) _budgets.Remove(address);
    }

    private bool Refuse(long now)
    {
        Interlocked.Increment(ref _repliesRefused);
        if (_noticeWindowStartMs == long.MinValue || now - _noticeWindowStartMs >= 60_000)
        {
            if (_refusedThisWindow > 0 && _notice is not null)
            {
                try
                {
                    _notice($"A2S query: {_refusedThisWindow} asks went unanswered since the last note because their " +
                            $"address was over its reply limit ({_budgets.Count} addresses tracked now)");
                }
                catch { /* logging must never break the responder */ }
            }
            _noticeWindowStartMs = now;
            _refusedThisWindow = 0;
        }
        _refusedThisWindow++;
        return false;
    }

    private void NotifyObserver(string queryType, IPEndPoint from)
    {
        if (_queryObserver is null) return;
        try { _queryObserver(queryType, from.ToString()); }
        catch { /* logging must never break the responder */ }
    }

    private byte[] BuildInfoReply()
    {
        var info = _infoProvider();
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write(-1);
        w.Write((byte)0x49);                          // I = info
        w.Write((byte)17);                            // protocol version
        WriteCString(w, info.Name);
        WriteCString(w, info.Map);
        WriteCString(w, info.Folder);
        WriteCString(w, info.Game);

        // Legacy 16-bit AppID = low 16 bits of the Steam AppID (ushort, NOT a
        // signed modulo). Modern clients ignore this in favor of the EDF
        // GameID below, which carries the full 64-bit AppID.
        var legacyAppId = (ushort)(info.SteamAppId & 0xFFFF);
        w.Write(legacyAppId);

        w.Write((byte)info.PlayerCount);
        w.Write((byte)info.MaxPlayers);
        w.Write((byte)0);                             // bots
        w.Write((byte)'d');                           // dedicated
        w.Write((byte)(OperatingSystem.IsLinux() ? 'l' : 'w'));
        w.Write((byte)(info.PasswordRequired ? 1 : 0));
        w.Write((byte)(info.VacSecured ? 1 : 0));
        WriteCString(w, info.Version);

        // EDF: port(0x80) + keywords(0x20) + gameid(0x01)
        const byte edf = 0x80 | 0x20 | 0x01;
        w.Write(edf);
        w.Write((short)info.GameplayPort);
        WriteCString(w, info.Keywords);
        w.Write((ulong)info.SteamAppId);              // 64-bit GameID = real Steam AppID
        return ms.ToArray();
    }

    private byte[] BuildPlayerOrRulesReply(bool isRules)
    {
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write(-1);

        if (!isRules)
        {
            var players = _playerProvider();
            w.Write((byte)0x44);                      // D = player
            w.Write((byte)players.Count);
            byte idx = 0;
            foreach (var p in players)
            {
                w.Write(idx++);
                WriteCString(w, p.Name);
                w.Write(p.Score);
                w.Write(p.ConnectSeconds);
            }
        }
        else
        {
            var rules = _rulesProvider();
            w.Write((byte)0x45);                      // E = rules
            w.Write((short)rules.Count);
            foreach (var (k, v) in rules)
            {
                WriteCString(w, k);
                WriteCString(w, v);
            }
        }
        return ms.ToArray();
    }

    private static void WriteCString(BinaryWriter w, string value)
    {
        w.Write(Encoding.UTF8.GetBytes(value));
        w.Write((byte)0);
    }
}

public readonly record struct ServerInfoSnapshot(
    string Name,
    string Map,
    string Folder,
    string Game,
    long SteamAppId,
    int PlayerCount,
    int MaxPlayers,
    bool PasswordRequired,
    bool VacSecured,
    string Version,
    int GameplayPort,
    string Keywords);

public readonly record struct PlayerInfoEntry(
    string Name,
    int Score,
    float ConnectSeconds);

/// <summary>
/// The per-address reply budget: <see cref="Burst"/> replies at once, refilled at <see cref="PerSecond"/>,
/// for at most <see cref="MaxTrackedAddresses"/> addresses seen in the last few seconds. The default leaves
/// a player's app (one ask every 30 seconds, two replies each), the hosting panel's poll and the public
/// server trackers far inside it.
/// </summary>
internal sealed record ReplyLimits(int Burst, double PerSecond, int MaxTrackedAddresses)
{
    public static ReplyLimits Default { get; } = new(Burst: 20, PerSecond: 5, MaxTrackedAddresses: 8192);
}

internal sealed class ReplyBudget
{
    public double Tokens;
    public long LastMs;
}
