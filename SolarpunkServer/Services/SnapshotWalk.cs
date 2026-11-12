using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SolarpunkServer.Services;

/// <summary>
/// The files a world snapshot zips, walked without ever going through a link.
/// <para>
/// A snapshot is a zip the owner can download, so it holds only what is really in the save
/// folder. The walk never goes into a folder that is a junction, a symbolic link or any other
/// reparse point, and leaves out a file that is a symbolic link, so whatever such a link points
/// at stays out of the zip. A file with a second name (a hard link, which looks like a plain file and
/// can be the same bytes as a file outside the save folder) is left out the same way. A save folder
/// that is itself a link is refused before any zip is made. Every plain file is kept, hidden and
/// system files included, as before.
/// </para>
/// <para>The sibling servers carry the same file; keep them in step.</para>
/// </summary>
internal static class SnapshotWalk
{
    // One folder at a time, so the walk itself decides about every sub-folder. Nothing is
    // skipped by attribute here: hidden and system files stay in the snapshot, as before.
    private static readonly EnumerationOptions OneFolder = new()
    {
        RecurseSubdirectories = false,
        AttributesToSkip = 0,
        IgnoreInaccessible = false,
        ReturnSpecialDirectories = false,
    };

    /// <summary>
    /// Every plain file under <paramref name="root"/>, as full paths. The links left out are added
    /// to <paramref name="linksLeftOut"/> as paths relative to the root (forward slashes).
    /// <paramref name="leaveOutFolder"/> gets a plain folder's relative path and returns true to
    /// leave that folder out without walking it.
    /// </summary>
    /// <exception cref="DirectoryNotFoundException">The save folder does not exist.</exception>
    /// <exception cref="IOException">The save folder itself is a link.</exception>
    internal static List<string> PlainFiles(string root, ICollection<string> linksLeftOut, Func<string, bool>? leaveOutFolder = null)
    {
        var top = new DirectoryInfo(root);
        if (!top.Exists)
            throw new DirectoryNotFoundException($"the save folder {top.FullName} does not exist");
        if (IsLink(top))
            throw new IOException($"the save folder {top.FullName} is a link or junction; no snapshot is taken through it");

        var files = new List<string>();
        var pending = new Stack<DirectoryInfo>();
        pending.Push(top);
        while (pending.Count > 0)
        {
            var folder = pending.Pop();
            foreach (var entry in folder.EnumerateFileSystemInfos("*", OneFolder))
            {
                if (IsLink(entry))
                {
                    linksLeftOut.Add(Relative(top.FullName, entry.FullName));
                    continue;
                }
                if (entry is DirectoryInfo sub)
                {
                    if (leaveOutFolder is not null && leaveOutFolder(Relative(top.FullName, sub.FullName))) continue;
                    pending.Push(sub);
                }
                else if (HardLinkCount(entry.FullName) > 1)
                {
                    linksLeftOut.Add(Relative(top.FullName, entry.FullName));
                }
                else
                {
                    files.Add(entry.FullName);
                }
            }
        }
        return files;
    }

    /// <summary>
    /// A folder that is any reparse point (junction, symbolic link, mount point) counts as a link.
    /// A file counts as one when it is a symbolic link; another kind of file reparse point (a
    /// deduplicated or cloud-backed file) is an ordinary file with its own bytes.
    /// </summary>
    internal static bool IsLink(FileSystemInfo info)
    {
        if ((info.Attributes & FileAttributes.ReparsePoint) == 0) return false;
        if (info is DirectoryInfo) return true;
        try { return info.LinkTarget is not null; }
        catch (IOException) { return true; }
        catch (UnauthorizedAccessException) { return true; }
    }

    /// <summary>
    /// How many names the file has, read on Windows without opening its contents (attributes access only,
    /// never through a link). Elsewhere, or when the count cannot be read, 1: the zip then opens the file
    /// as it always did, and a file it cannot read still fails the snapshot loudly.
    /// </summary>
    internal static uint HardLinkCount(string path)
    {
        if (!OperatingSystem.IsWindows()) return 1;
        using var handle = CreateFileW(path, FileReadAttributes, FileShareReadWriteDelete, IntPtr.Zero, OpenExisting,
            FileFlagBackupSemantics | FileFlagOpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid) return 1;
        // BY_HANDLE_FILE_INFORMATION is 13 DWORDs; nNumberOfLinks is the 11th.
        var information = new uint[13];
        return GetFileInformationByHandle(handle, information) ? information[10] : 1;
    }

    private const uint FileReadAttributes = 0x80;
    private const uint FileShareReadWriteDelete = 0x7;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileFlagOpenReparsePoint = 0x00200000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle hFile,
        [Out, MarshalAs(UnmanagedType.LPArray, SizeConst = 13)] uint[] lpFileInformation);

    private static string Relative(string root, string path) => Path.GetRelativePath(root, path).Replace('\\', '/');
}
