using System.Net;
using System.Security.Cryptography;
using System.Text;
using FluentAssertions;
using Microsoft.Extensions.Logging;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

// A route that throws answers 500 with a fixed error, never the exception's text: that text can
// carry a path on the server's machine, and the HTTP door answers anyone a server owner lets in
// (BeaconServer has answered "internal error" here since 2026-10-30). The signed body the route was
// given is still deleted from the upload temp folder, so a throw never leaves an upload of up to
// MaxUploadBytes behind until the next start's leftover sweep.
[Collection("SourceGuard")]
public sealed class HttpErrorReplyTests : IDisposable
{
    public HttpErrorReplyTests() => TestNet.ResetGuard();
    public void Dispose() => TestNet.ResetGuard();

    [Fact]
    public async Task A_route_that_throws_answers_a_fixed_error_and_leaves_no_upload_behind()
    {
        var log = new ListLogger<SolarpunkHttpService>();
        await using var h = await HttpLiveHarness.StartAsync(log);

        // The save folder is a file now, so the upload route's folder step throws an IOException
        // whose message names the path.
        Directory.Delete(h.SaveDir);
        File.WriteAllText(h.SaveDir, "not a folder");

        var body = new byte[4096];
        RandomNumberGenerator.Fill(body);
        var bodySha = HttpLiveHarness.Sha(body);

        var (status, text) = await SignedWithReplyAsync(h, "POST", "/api/v1/snapshots", body);

        status.Should().Be(500);
        text.Should().Be("{\"error\":\"internal error\"}");
        text.Should().NotContain(h.SaveDir).And.NotContain("saves");
        log.Entries.Should().Contain(e => e.Level == LogLevel.Error && e.Text.Contains("POST /api/v1/snapshots threw"),
            "the detail stays in the server's own log");

        // The body was written to the upload temp folder before the route ran; it must not stay there.
        var left = true;
        for (var i = 0; i < 50 && left; i++)
        {
            left = UploadTempHolds(bodySha, body.Length);
            if (left) await Task.Delay(50);
        }
        left.Should().BeFalse("a route that throws still deletes the signed body it was given");
    }

    private static bool UploadTempHolds(string sha, int length)
    {
        foreach (var f in HttpLiveHarness.UploadTempFiles())
        {
            try
            {
                if (new FileInfo(f).Length != length) continue;
                if (HttpLiveHarness.Sha(File.ReadAllBytes(f)) == sha) return true;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return false;
    }

    private static async Task<(int Status, string Text)> SignedWithReplyAsync(
        HttpLiveHarness h, string method, string path, byte[] body)
    {
        var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var sig = HmacRequestAuth.Sign(h.Key, HmacRequestAuth.CanonicalString(method, path, ts, HttpLiveHarness.Sha(body)));
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        using var req = new HttpRequestMessage(new HttpMethod(method), $"http://{IPAddress.Loopback}:{h.Port}{path}");
        req.Headers.Add(AdminRequestGate.TimestampHeader, ts.ToString());
        req.Headers.Add(AdminRequestGate.SignatureHeader, sig);
        req.Content = new ByteArrayContent(body);
        using var resp = await http.SendAsync(req);
        return ((int)resp.StatusCode, Encoding.UTF8.GetString(await resp.Content.ReadAsByteArrayAsync()));
    }
}
