using System;
using System.Diagnostics;
using System.IO;

namespace SolarpunkServer.Services;

/// <summary>
/// Reports whether the Solarpunk game process named in <c>GamePidFile</c> is alive.
/// Used as an OR condition alongside the plugin heartbeat so a server that is genuinely
/// up — e.g. parked in its always-on lobby, where the in-game plugin may not be pinging
/// the pipe — still reports "online" to A2S and <c>/api/v1/health</c> instead of looking
/// dead in the launcher. Validates the process NAME (not just the PID) to defend against
/// PID reuse: a recycled PID belonging to some unrelated process must not read as online.
/// </summary>
public static class GameProcessProbe
{
    // Matches SolarpunkSteam-Win64-Shipping(.exe); ProcessName has no extension.
    private const string ExeNameFragment = "Solarpunk";

    public static bool IsAlive(string? pidFile)
    {
        if (string.IsNullOrWhiteSpace(pidFile))
        {
            Serilog.Log.Debug("GameProcessProbe: no pidfile configured -> not alive");
            return false;
        }
        try
        {
            if (!File.Exists(pidFile))
            {
                Serilog.Log.Debug("GameProcessProbe: pidfile missing {PidFile} -> not alive", pidFile);
                return false;
            }
            var raw = File.ReadAllText(pidFile).Trim();
            if (!int.TryParse(raw, out var pid) || pid <= 0)
            {
                Serilog.Log.Debug("GameProcessProbe: pidfile {PidFile} content '{Raw}' not a valid pid -> not alive", pidFile, raw);
                return false;
            }

            using var p = Process.GetProcessById(pid);
            if (p.HasExited)
            {
                Serilog.Log.Debug("GameProcessProbe: pid {Pid} has exited -> not alive", pid);
                return false;
            }

            try
            {
                var name = p.ProcessName;
                var nameMatch = name.IndexOf(ExeNameFragment, StringComparison.OrdinalIgnoreCase) >= 0;
                if (nameMatch)
                {
                    Serilog.Log.Debug("GameProcessProbe: pid {Pid} name='{Name}' -> alive", pid, name);
                    return true;
                }
                Serilog.Log.Debug("GameProcessProbe: pid {Pid} name='{Name}' did not match", pid, name);
            }
            catch (Exception ex)
            {
                Serilog.Log.Debug("GameProcessProbe: pid {Pid} ProcessName unavailable ({Ex})", pid, ex.GetType().Name);
            }

            try
            {
                var exe = p.MainModule?.FileName ?? "";
                var pathMatch = exe.IndexOf(ExeNameFragment, StringComparison.OrdinalIgnoreCase) >= 0;
                if (pathMatch)
                {
                    Serilog.Log.Debug("GameProcessProbe: pid {Pid} exe='{Exe}' -> alive", pid, exe);
                    return true;
                }
                Serilog.Log.Debug("GameProcessProbe: pid {Pid} exe='{Exe}' did not match", pid, exe);
            }
            catch (Exception ex)
            {
                Serilog.Log.Debug("GameProcessProbe: pid {Pid} MainModule unavailable ({Ex})", pid, ex.GetType().Name);
            }

            // Health is a read-only "is this instance probably up?" signal. The
            // restart/restore kill paths do stricter path ownership checks before
            // touching a process. Here, a live PID from this instance's pidfile is
            // enough to avoid false-down panel/launcher status on hosts where
            // ProcessName/MainModule reads intermittently fail under Windows.
            Serilog.Log.Debug("GameProcessProbe: pid {Pid} exists but name/path validation was unavailable or inconclusive -> alive", pid);
            return true;
        }
        catch (Exception ex)
        {
            // GetProcessById throws if the PID isn't running; any read/race error = not alive.
            Serilog.Log.Debug("GameProcessProbe: probe of {PidFile} failed ({Ex}) -> not alive", pidFile, ex.GetType().Name);
            return false;
        }
    }
}
