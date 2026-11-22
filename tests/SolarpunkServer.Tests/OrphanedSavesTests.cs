using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// The world files in SaveGames\_sundial_orphaned_saves can be an owner's own copies, or the only copy of a world an
/// upload replaced. The server never removes one, at a start or after a backup.
/// </summary>
public sealed class OrphanedSavesTests : IDisposable
{
    private readonly RestoreTestServer _s = new();

    public void Dispose() => _s.Dispose();

    [Fact]
    public async Task Nothing_set_aside_is_ever_removed()
    {
        var folder = Path.Combine(_s.Tree, "_sundial_orphaned_saves");
        Directory.CreateDirectory(folder);
        var kept = Enumerable.Range(0, 60).Select(i =>
        {
            var name = i % 2 == 0 ? $"202501010000{i:D2}-previous-World.sav" : $"my copy {i}.sav";
            var path = Path.Combine(folder, name);
            File.WriteAllText(path, "world");
            return path;
        }).ToList();

        await _s.Service.StartAsync(CancellationToken.None);
        Assert.NotNull(await _s.Service.SnapshotAsync("rcon"));
        await _s.Service.StopAsync(CancellationToken.None);

        Assert.All(kept, path => Assert.True(File.Exists(path), path));
    }
}
