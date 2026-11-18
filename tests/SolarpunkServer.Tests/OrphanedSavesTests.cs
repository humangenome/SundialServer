using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// The world files the host mod sets aside in SaveGames\_sundial_orphaned_saves have a room (2026-11-18): the newest
/// MaxOrphanedSavesKept within MaxOrphanedSavesBytes. Only plain files directly in that folder are removed, never
/// through a link.
/// </summary>
public sealed class OrphanedSavesTests : IDisposable
{
    private const long KiB = RestoreTestServer.KiB;
    private readonly RestoreTestServer _s = new();

    public void Dispose() => _s.Dispose();

    private string Folder => Path.Combine(_s.Tree, SaveOrchestratorService.OrphanedSavesFolder);

    // A set-aside file named as the host mod names it: <yyyyMMddHHmmss>-<what>.
    private string SetAside(int minutesAgo, string what, long bytes = KiB)
    {
        Directory.CreateDirectory(Folder);
        var stamp = DateTime.Now.AddMinutes(-minutesAgo).ToString("yyyyMMddHHmmss");
        var path = Path.Combine(Folder, $"{stamp}-{what}");
        File.WriteAllBytes(path, new byte[bytes]);
        return path;
    }

    [Fact]
    public void Keeps_the_newest_twenty_by_the_time_in_their_names()
    {
        _s.Options.MaxOrphanedSavesKept = 20;
        // Written newest first, so the file times say the opposite of the names.
        var paths = Enumerable.Range(0, 25).Select(i => SetAside(i, $"previous-World{i}.sav")).ToList();

        _s.Service.PruneOrphanedSaves();

        Assert.All(paths.Take(20), p => Assert.True(File.Exists(p)));
        Assert.All(paths.Skip(20), p => Assert.False(File.Exists(p)));
    }

    [Fact]
    public void Keeps_the_room_in_bytes_and_always_the_newest()
    {
        _s.Options.MaxOrphanedSavesBytes = 500 * KiB;
        var newest = SetAside(0, "previous-World1.sav", 600 * KiB);
        var older = Enumerable.Range(1, 3).Select(i => SetAside(i, $"World1-{i}.sav", 100 * KiB)).ToList();

        _s.Service.PruneOrphanedSaves();

        Assert.True(File.Exists(newest));
        Assert.All(older, p => Assert.False(File.Exists(p)));
    }

    [Fact]
    public void A_link_in_the_folder_is_never_removed_or_followed()
    {
        _s.Options.MaxOrphanedSavesKept = 1;
        SetAside(0, "previous-World1.sav");
        SetAside(5, "old.sav");
        var link = Path.Combine(Folder, "19990101000000-linked");
        _s.MakeFolderLink(link, _s.Outside);

        _s.Service.PruneOrphanedSaves();

        Assert.True(RestoreFolders.IsLink(link));
        _s.OutsideUntouched();
    }

    [Fact]
    public void Nothing_is_removed_when_the_folder_is_a_link()
    {
        _s.Options.MaxOrphanedSavesKept = 1;
        for (var i = 0; i < 3; i++)
            File.WriteAllText(Path.Combine(_s.Outside, $"2026010100000{i}-x.sav"), "outside");
        _s.MakeFolderLink(Folder, _s.Outside);

        _s.Service.PruneOrphanedSaves();

        Assert.Equal(4, Directory.GetFiles(_s.Outside).Length);
    }

    [Fact]
    public void Nothing_is_removed_when_SaveGames_is_a_link()
    {
        _s.Options.MaxOrphanedSavesKept = 1;
        var orphans = Path.Combine(_s.Outside, SaveOrchestratorService.OrphanedSavesFolder);
        Directory.CreateDirectory(orphans);
        for (var i = 0; i < 3; i++)
            File.WriteAllText(Path.Combine(orphans, $"2026010100000{i}-x.sav"), "outside");
        Directory.Delete(_s.Tree, recursive: true);
        _s.MakeFolderLink(_s.Tree, _s.Outside);

        _s.Service.PruneOrphanedSaves();

        Assert.Equal(3, Directory.GetFiles(orphans).Length);
    }

    [Fact]
    public void Runs_after_every_snapshot_rotation()
    {
        _s.Options.MaxOrphanedSavesKept = 2;
        var paths = Enumerable.Range(0, 4).Select(i => SetAside(i, $"World1-{i}.sav")).ToList();

        _s.Service.RotateOldSnapshots();

        Assert.Equal(2, Directory.GetFiles(Folder).Length);
        Assert.True(File.Exists(paths[0]));
        Assert.False(File.Exists(paths[3]));
    }

    [Fact]
    public void The_live_world_and_other_save_files_are_never_touched()
    {
        _s.Options.MaxOrphanedSavesKept = 1;
        File.WriteAllText(Path.Combine(_s.Tree, "gp_data.sav"), "players");
        SetAside(0, "a.sav");
        SetAside(1, "b.sav");

        _s.Service.PruneOrphanedSaves();

        Assert.Equal("live world", _s.LiveText());
        Assert.Equal("players", File.ReadAllText(Path.Combine(_s.Tree, "gp_data.sav")));
        Assert.Single(Directory.GetFiles(Folder));
    }
}
