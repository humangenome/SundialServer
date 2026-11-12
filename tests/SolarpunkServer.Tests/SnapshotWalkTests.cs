using System.Diagnostics;
using System.IO.Compression;
using SolarpunkServer.Services;
using Xunit;

namespace SolarpunkServer.Tests;

/// <summary>
/// A snapshot never follows a link: a folder link (a junction on Windows) or a file link inside the
/// save folder stays out of the zip, and a save folder that is itself a link is refused with no zip.
/// </summary>
public sealed class SnapshotWalkTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "snapwalk-" + Guid.NewGuid().ToString("N"));
    private string Save => Path.Combine(_root, "save");
    private string Outside => Path.Combine(_root, "outside");
    private string Zip => Path.Combine(_root, "snapshot.zip");

    public SnapshotWalkTests()
    {
        Directory.CreateDirectory(Path.Combine(Save, "slot", "deeper"));
        File.WriteAllText(Path.Combine(Save, "slot", "world.sav"), "world");
        File.WriteAllText(Path.Combine(Save, "slot", "deeper", "part.sav"), "part");
        File.WriteAllText(Path.Combine(Save, "top.sav"), "top");
        Directory.CreateDirectory(Outside);
        File.WriteAllText(Path.Combine(Outside, "outside.txt"), "not part of the save");
    }

    public void Dispose()
    {
        // Every link this class made goes first, by itself (the link only, never what it points at).
        foreach (var link in new[] { Path.Combine(Save, "slot", "linked"), Path.Combine(_root, "linked-save"), Path.Combine(Save, "linked-file.txt") })
        {
            try
            {
                var info = new FileInfo(link);
                if ((int)info.Attributes == -1 || !info.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                if (OperatingSystem.IsWindows() && info.Attributes.HasFlag(FileAttributes.Directory)) Directory.Delete(link, recursive: false);
                else File.Delete(link);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        try { Directory.Delete(_root, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    [Fact]
    public void WithoutLinksEveryFileIsInTheSnapshot()
    {
        var left = SaveOrchestratorService.CreateSaveGamesZip(Save, Zip);

        Assert.Empty(left);
        Assert.Equal(new[] { "slot/deeper/part.sav", "slot/world.sav", "top.sav" }, EntryNames());
    }

    [Fact]
    public void AFolderLinkInTheSaveFolderStaysOutOfTheSnapshot()
    {
        MakeFolderLink(Path.Combine(Save, "slot", "linked"), Outside);

        var left = SaveOrchestratorService.CreateSaveGamesZip(Save, Zip);

        Assert.Equal(new[] { "slot/linked" }, left);
        Assert.Equal(new[] { "slot/deeper/part.sav", "slot/world.sav", "top.sav" }, EntryNames());
        Assert.True(File.Exists(Path.Combine(Outside, "outside.txt")));
    }

    [Fact]
    public void AFileLinkInTheSaveFolderStaysOutOfTheSnapshot()
    {
        var link = Path.Combine(Save, "linked-file.txt");
        try { File.CreateSymbolicLink(link, Path.Combine(Outside, "outside.txt")); }
        catch (Exception e) when (OperatingSystem.IsWindows() && (e is UnauthorizedAccessException || e is IOException))
        {
            return; // this Windows account may not make file links; the folder-link tests still run
        }

        var left = SaveOrchestratorService.CreateSaveGamesZip(Save, Zip);

        Assert.Equal(new[] { "linked-file.txt" }, left);
        Assert.DoesNotContain("linked-file.txt", EntryNames());
    }

    [Fact]
    public void ASaveFolderThatIsALinkIsRefusedAndNoZipIsMade()
    {
        var linkedSave = Path.Combine(_root, "linked-save");
        MakeFolderLink(linkedSave, Save);

        var e = Assert.Throws<IOException>(() => SaveOrchestratorService.CreateSaveGamesZip(linkedSave, Zip));

        Assert.Contains("link", e.Message);
        Assert.False(File.Exists(Zip));
    }

    [Fact]
    public void HiddenFilesStayInTheSnapshot()
    {
        var hidden = Path.Combine(Save, "slot", ".hidden.sav");
        File.WriteAllText(hidden, "hidden");
        if (OperatingSystem.IsWindows()) File.SetAttributes(hidden, File.GetAttributes(hidden) | FileAttributes.Hidden);

        SaveOrchestratorService.CreateSaveGamesZip(Save, Zip);

        Assert.Contains("slot/.hidden.sav", EntryNames());
    }
    private string[] EntryNames()
    {
        using var zip = ZipFile.OpenRead(Zip);
        return zip.Entries.Select(e => e.FullName).OrderBy(n => n, StringComparer.Ordinal).ToArray();
    }

    // A junction on Windows (no special right needed), a symbolic link elsewhere.
    private static void MakeFolderLink(string link, string target)
    {
        if (!OperatingSystem.IsWindows())
        {
            Directory.CreateSymbolicLink(link, target);
            return;
        }
        var psi = new ProcessStartInfo("cmd.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in new[] { "/d", "/c", "mklink", "/J", link, target }) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        p.WaitForExit(30_000);
        if (p.ExitCode != 0) throw new IOException("mklink /J failed: " + p.StandardError.ReadToEnd());
    }
}
