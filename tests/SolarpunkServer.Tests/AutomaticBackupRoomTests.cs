using SolarpunkServer.Configuration;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// The room is for automatic backups alone: 512 MB, or a tenth of the drive's free space when that is less.
/// What an owner made, and what can't be told, takes none of it and is never evicted.
/// </summary>
public sealed class AutomaticBackupRoomTests : IDisposable
{
    private const long KiB = RestoreTestServer.KiB;
    private readonly RestoreTestServer _s = new();
    private readonly long _now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    public void Dispose() => _s.Dispose();

    private string Stored(string id, int minutesAgo, long bytes)
    {
        Directory.CreateDirectory(_s.SaveDir);
        var path = Path.Combine(_s.SaveDir, id + ".zip");
        File.WriteAllBytes(path, new byte[16]);
        _s.Service.Database.RecordSnapshot(new(id, _now - minutesAgo * 60, path, bytes, "00", 30));
        return path;
    }

    [Fact]
    public void The_room_is_512_MB_and_has_no_count()
    {
        Assert.Equal(512L * 1024 * 1024, new SolarpunkServerOptions().MaxSnapshotBytes);
        Assert.Equal(0, new SolarpunkServerOptions().MaxSnapshotsKept);
    }

    [Fact]
    public void A_tenth_of_the_free_space_is_the_room_when_that_is_less()
    {
        _s.Options.MaxSnapshotBytes = 10_000 * KiB;
        _s.Service.FreeSpaceProbe = _ => 2_500 * KiB;
        var oldest = Stored("auto-1", 3, 100 * KiB);
        var middle = Stored("auto-2", 2, 100 * KiB);
        var newest = Stored("auto-3", 1, 100 * KiB);

        _s.Service.RotateOldSnapshots();

        Assert.False(File.Exists(oldest));
        Assert.True(File.Exists(middle));
        Assert.True(File.Exists(newest));
    }

    [Fact]
    public void Owner_made_and_unknown_backups_take_none_of_the_room()
    {
        _s.Options.MaxSnapshotsKept = 0;
        _s.Options.MaxSnapshotBytes = 500 * KiB;
        _s.Service.FreeSpaceProbe = _ => null;
        var owners = Enumerable.Range(0, 40).Select(i => Stored(new[] { "snap-", "upload-", "unknown-" }[i % 3] + i, 100 + i, 10_000 * KiB)).ToList();
        var automatic = new[] { Stored("auto-1", 2, 200 * KiB), Stored("auto-2", 1, 200 * KiB) };

        _s.Service.RotateOldSnapshots();

        Assert.All(owners.Concat(automatic), path => Assert.True(File.Exists(path), path));
    }
}
