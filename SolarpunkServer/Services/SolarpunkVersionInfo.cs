using System.Reflection;

namespace SolarpunkServer.Services;

/// <summary>
/// Single source of truth for version strings surfaced to operators, A2S
/// queries, and the startup banner. Solarpunk's own version comes from the
/// assembly; Solarpunk's build number is read at runtime from the host's UE log.
/// </summary>
public static class SolarpunkVersionInfo
{
    public static string SolarpunkVersion { get; } = ResolveSolarpunkVersion();

    public static string SpBuild { get; private set; } = "unknown";

    /// <summary>
    /// Called once the host log is parsed. Subsequent A2S query responses +
    /// banner refreshes include it.
    /// </summary>
    public static void SetSpBuild(string build)
    {
        if (!string.IsNullOrWhiteSpace(build)) SpBuild = build.Trim();
    }

    private static string ResolveSolarpunkVersion()
    {
        var asm = Assembly.GetExecutingAssembly();
        var info = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!string.IsNullOrWhiteSpace(info))
        {
            // Strip "+commitsha" suffix MSBuild appends in default release builds.
            var plus = info.IndexOf('+');
            return plus > 0 ? info[..plus] : info;
        }
        return asm.GetName().Version?.ToString(3) ?? "0.0.0";
    }
}
