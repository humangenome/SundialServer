using System.IO;

namespace SolarpunkServer.Services;

/// <summary>
/// The RCON kick hand-off to the game side: write <c>runtime.kick-request</c> ("&lt;token&gt; &lt;id&gt;")
/// next to SolarpunkServer.exe and wait for <c>runtime.kick-done</c> ("&lt;token&gt; &lt;result&gt; &lt;unix time&gt;"),
/// which the SolarpunkAuth mod writes from its 1 s sweep. Same shape as the stop step's save request.
/// </summary>
internal static class KickRequestFile
{
    public static async Task<string?> AskAsync(string dir, string id, TimeSpan wait)
    {
        var req = Path.Combine(dir, "runtime.kick-request");
        var done = Path.Combine(dir, "runtime.kick-done");
        var token = "kick-" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        try { File.Delete(done); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        File.WriteAllText(req + ".tmp", $"{token} {id}\n");
        File.Move(req + ".tmp", req, overwrite: true);
        var until = DateTime.UtcNow + wait;
        while (DateTime.UtcNow < until)
        {
            await Task.Delay(200).ConfigureAwait(false);
            string? body = null;
            try { body = File.ReadAllText(done); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            if (body is null || !body.StartsWith(token + " ", StringComparison.Ordinal)) continue;
            return ParseResult(body[(token.Length + 1)..]);
        }
        try { if (File.Exists(req) && File.ReadAllText(req).StartsWith(token + " ", StringComparison.Ordinal)) File.Delete(req); }
        catch (IOException) { } catch (UnauthorizedAccessException) { }
        return null;
    }

    // "<result words> <unix time>": the result without the trailing time.
    internal static string ParseResult(string tail)
    {
        var t = tail.Trim();
        var cut = t.LastIndexOf(' ');
        if (cut > 0 && long.TryParse(t[(cut + 1)..], out _)) t = t[..cut];
        return t;
    }
}
