using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;

namespace SolarpunkServer.Tests;

// Helpers for the per-address limit tests. Loopback is never limited, so these tests talk to the
// listener through this machine's own non-loopback address, which the listener then sees as the
// caller's address. Written without naming the limit class, so the same tests also build against
// a listener that has no limits (that is how they were shown to fail before the limits existed).
internal static class TestNet
{
    public static IPAddress OwnAddress()
    {
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var ua in nic.GetIPProperties().UnicastAddresses)
            {
                var a = ua.Address;
                if (a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a)
                    && !a.ToString().StartsWith("169.254.", StringComparison.Ordinal))
                    return a;
            }
        }
        throw new InvalidOperationException("this machine has no non-loopback IPv4 address to test the per-address limits with");
    }

    // The failure table is process-wide; start each limit test clean. A no-op where it does not exist.
    public static void ResetGuard() =>
        Type.GetType("Solarpunk.Rcon.SourceGuard, Solarpunk.Rcon")?.GetMethod("ResetForTests")?.Invoke(null, null);
}

internal sealed class ListLogger<T> : ILogger<T>
{
    private readonly List<(LogLevel Level, string Text)> _entries = new();

    public IReadOnlyList<(LogLevel Level, string Text)> Entries
    {
        get { lock (_entries) return _entries.ToList(); }
    }

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
    public bool IsEnabled(LogLevel logLevel) => true;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
        Func<TState, Exception?, string> formatter)
    {
        lock (_entries) _entries.Add((logLevel, formatter(state, exception)));
    }
}
