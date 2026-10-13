using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace SolarpunkServer;

/// <summary>
/// One-shot CLI verb that starts the game with DLLs loaded from its first moment:
/// <code>SolarpunkServer.exe launch --exe &lt;game exe&gt; --workdir &lt;dir&gt; (--args "&lt;game arguments&gt;" | --args-file &lt;file&gt;)
///        --dll &lt;path&gt; [--dll &lt;path&gt; ...] [--optional-dll &lt;path&gt; ...] [--affinity &lt;hex mask&gt;]</code>
///
/// The game is created suspended, one LoadLibraryW per DLL is queued on its main thread
/// (QueueUserAPC), and the thread is resumed: the DLLs load right after Windows has set the
/// process up and before the game's own code runs. Two loads need that: the Epic identity
/// store must re-point the EOS SDK's credential imports before Redpoint signs in (about 3 s
/// after start; an inject one second in lost that race), and the UE4SS build with the string
/// fix waits forever at "Verifying FName constructor" when it arrives after the engine has
/// settled. Same AMSI reasoning as <see cref="InjectCommand"/>: this lives in the compiled exe.
///
/// Prints "pid=&lt;pid&gt;" and exits 0 once the game runs. Exit 2 = bad arguments or a missing
/// required DLL; 1 = the game could not be started (nothing is left running); 3 = not Windows.
/// </summary>
internal static class LaunchCommand
{
    private const uint CreateSuspended = 0x00000004;
    private const uint CreateNoWindow = 0x08000000;
    private const uint MemCommitReserve = 0x3000;
    private const uint PageReadWrite = 0x04;

    public static int Run(string[] args)
    {
        if (!TryParse(args, out var opt, out var error))
        {
            Log("ERROR: " + error);
            Log("usage: SolarpunkServer.exe launch --exe <path> --workdir <dir> --args \"<arguments>\" " +
                "(or --args-file <file>) --dll <path> [--dll <path> ...] [--optional-dll <path> ...] [--affinity <hex>]");
            return 2;
        }
        if (!OperatingSystem.IsWindows()) { Log("ERROR: launch is Windows-only"); return 3; }
        if (!File.Exists(opt.Exe)) { Log("ERROR: exe not found: " + opt.Exe); return 2; }

        var dlls = new List<string>();
        foreach (var dll in opt.Dlls)
        {
            if (!File.Exists(dll)) { Log("ERROR: dll not found: " + dll); return 2; }
            dlls.Add(dll);
        }
        foreach (var dll in opt.OptionalDlls)
        {
            if (File.Exists(dll)) dlls.Add(dll);
            else Log("SKIP: optional dll not present: " + dll);
        }

        var si = new StartupInfo { cb = Marshal.SizeOf<StartupInfo>() };
        var cmd = new StringBuilder("\"" + opt.Exe + "\" " + opt.Args);
        if (!CreateProcessW(opt.Exe, cmd, IntPtr.Zero, IntPtr.Zero, false, CreateSuspended | CreateNoWindow,
                IntPtr.Zero, opt.WorkDir, ref si, out var pi))
        {
            Log("ERROR: CreateProcess failed, error " + Marshal.GetLastWin32Error());
            return 1;
        }
        try
        {
            var loadLibrary = GetProcAddress(GetModuleHandleW("kernel32.dll"), "LoadLibraryW");
            if (loadLibrary == IntPtr.Zero) return Abort(pi, "LoadLibraryW not found");
            foreach (var dll in dlls)
            {
                var bytes = Encoding.Unicode.GetBytes(dll + "\0");
                var mem = VirtualAllocEx(pi.hProcess, IntPtr.Zero, (uint)bytes.Length, MemCommitReserve, PageReadWrite);
                if (mem == IntPtr.Zero || !WriteProcessMemory(pi.hProcess, mem, bytes, (uint)bytes.Length, out _))
                    return Abort(pi, "could not write the path of " + dll);
                if (QueueUserAPC(loadLibrary, pi.hThread, mem) == 0)
                    return Abort(pi, "could not queue the load of " + dll + ", error " + Marshal.GetLastWin32Error());
                Log("queued " + dll);
            }
            if (opt.Affinity != 0 && !SetProcessAffinityMask(pi.hProcess, (UIntPtr)opt.Affinity))
                Log("WARN: affinity not applied, error " + Marshal.GetLastWin32Error());
            if (ResumeThread(pi.hThread) == uint.MaxValue) return Abort(pi, "could not resume the game");
            Console.Out.WriteLine("pid=" + pi.dwProcessId.ToString(CultureInfo.InvariantCulture));
            Log("launched pid=" + pi.dwProcessId + " with " + dlls.Count + " dll(s) loaded at start");
            return 0;
        }
        finally
        {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
    }

    private static int Abort(ProcessInformation pi, string why)
    {
        TerminateProcess(pi.hProcess, 1);
        Log("ERROR: " + why + "; the suspended game was ended");
        return 1;
    }

    internal static bool TryParse(string[] args, out LaunchOptions opt, out string error)
    {
        opt = new LaunchOptions();
        error = "";
        for (var i = 0; i < args.Length; i++)
        {
            string Next(string name)
            {
                if (++i >= args.Length) throw new ArgumentException(name + " requires a value");
                return args[i];
            }
            try
            {
                switch (args[i])
                {
                    case "--exe": opt.Exe = Next("--exe"); break;
                    case "--workdir": opt.WorkDir = Next("--workdir"); break;
                    case "--args": opt.Args = Next("--args"); break;
                    case "--args-file":
                        var path = Next("--args-file");
                        if (!File.Exists(path)) { error = "--args-file not found: " + path; return false; }
                        opt.Args = File.ReadAllText(path).Trim();
                        break;
                    case "--dll": opt.Dlls.Add(Next("--dll")); break;
                    case "--optional-dll": opt.OptionalDlls.Add(Next("--optional-dll")); break;
                    case "--affinity":
                        var raw = Next("--affinity");
                        if (raw.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) raw = raw[2..];
                        if (!ulong.TryParse(raw, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var mask))
                        { error = "--affinity must be a hex mask"; return false; }
                        opt.Affinity = mask;
                        break;
                    default: error = "unknown option " + args[i]; return false;
                }
            }
            catch (ArgumentException e) { error = e.Message; return false; }
        }
        if (string.IsNullOrWhiteSpace(opt.Exe)) { error = "--exe is required"; return false; }
        if (string.IsNullOrWhiteSpace(opt.WorkDir)) { error = "--workdir is required"; return false; }
        if (opt.Dlls.Count == 0 && opt.OptionalDlls.Count == 0) { error = "at least one --dll is required"; return false; }
        return true;
    }

    private static void Log(string message) =>
        Console.Error.WriteLine("[" + DateTime.Now.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture) + "] launch: " + message);

    internal sealed class LaunchOptions
    {
        public string Exe = "";
        public string WorkDir = "";
        public string Args = "";
        public List<string> Dlls = new();
        public List<string> OptionalDlls = new();
        public ulong Affinity;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb; public string? lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles, uint dwCreationFlags,
        IntPtr lpEnvironment, string lpCurrentDirectory, ref StartupInfo lpStartupInfo, out ProcessInformation lpProcessInformation);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, uint dwSize, uint flAllocationType, uint flProtect);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out int lpNumberOfBytesWritten);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandleW(string lpModuleName);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    private static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint QueueUserAPC(IntPtr pfnAPC, IntPtr hThread, IntPtr dwData);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr hThread);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessAffinityMask(IntPtr hProcess, UIntPtr dwProcessAffinityMask);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr hObject);
}
