using SolarpunkServer.Configuration;
using SolarpunkServer.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using Serilog;

namespace SolarpunkServer;

public static class Program
{
    public static int Main(string[] args)
    {
        // One-shot CLI verb: load a DLL (UE4SS.dll / the native plugin) into the
        // running game process from this COMPILED exe instead of from the
        // AMSI-scanned PowerShell launch script. Runs and exits without starting
        // the host. See InjectCommand for the AMSI rationale.
        if (args.Length > 0 && string.Equals(args[0], "inject", StringComparison.OrdinalIgnoreCase))
        {
            return InjectCommand.Run(args[1..]);
        }

        // Verbose toggle: Solarpunk:Verbose (config / appsettings.json) OR the
        // SOLARPUNK_VERBOSE env var. When on, the minimum log level drops to Debug
        // so the RCON / A2S / HTTP / heartbeat instrumentation is emitted. Off by
        // default keeps the steady-state log to Information.
        var verbose = ResolveVerbose(args);
        var minLevel = verbose
            ? Serilog.Events.LogEventLevel.Debug
            : Serilog.Events.LogEventLevel.Information;

        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Is(minLevel)
            .Enrich.FromLogContext()
            .WriteTo.Console(outputTemplate:
                "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj}{NewLine}{Exception}")
            .WriteTo.File(
                formatter: new Serilog.Formatting.Compact.CompactJsonFormatter(),
                path: "logs/solarpunk-.log",
                rollingInterval: RollingInterval.Day,
                retainedFileCountLimit: 14)
            .CreateBootstrapLogger();

        try
        {
            PrintStartupBanner();
            Log.Information("Verbose logging {State} (min level {Level})",
                verbose ? "ON" : "off", minLevel);

            var builder = Host.CreateApplicationBuilder(args);
            builder.Services.AddSerilog();

            builder.Services.Configure<SolarpunkServerOptions>(builder.Configuration.GetSection("Solarpunk"));

            builder.Services.AddSingleton<InstanceIdentityProvider>();
            builder.Services.AddSingleton<HmacKeyService>();
            builder.Services.AddSingleton<PipeServerState>();
            builder.Services.AddSingleton<SpRestartCoordinator>();

            builder.Services.AddSingleton<SaveOrchestratorService>();
            builder.Services.AddSingleton<ChatService>();
            builder.Services.AddHostedService(sp => sp.GetRequiredService<SaveOrchestratorService>());
            builder.Services.AddHostedService(sp => sp.GetRequiredService<ChatService>());
            builder.Services.AddHostedService<NamedPipeServerService>();
            builder.Services.AddHostedService<HeartbeatWatchdogService>();
            builder.Services.AddHostedService<SourceQueryHostedService>();
            builder.Services.AddHostedService<RconHostedService>();
            builder.Services.AddHostedService<SpProcessSupervisorService>();
            builder.Services.AddHostedService<SpLogTailService>();
            builder.Services.AddHostedService<SolarpunkHttpService>();
            builder.Services.AddHostedService<RosterFileWatcherService>();

            var host = builder.Build();

            // Emit the per-instance identity line now that DI has bound options.
            var opts = host.Services.GetRequiredService<IOptions<SolarpunkServerOptions>>().Value;
            Log.Information("Instance {Instance} | gameplay:{GP} query:{QP} rcon:{RP} pipe:{Pipe}",
                opts.InstanceId, opts.GameplayPort, opts.QueryPort, opts.RconPort, opts.PipeName);
            Log.Information("Save dir: {Dir}", opts.SaveDir);
            Log.Information("Solarpunk user dir: {Dir}", opts.GameUserDir);

            host.Run();
            return 0;
        }
        catch (Exception ex)
        {
            Log.Fatal(ex, "SolarpunkServer terminated unexpectedly");
            return 1;
        }
        finally
        {
            Log.CloseAndFlush();
        }
    }

    // Resolves the verbose flag from the same sources the host will bind later:
    // appsettings.json (Solarpunk:Verbose), env vars, and command-line args, plus
    // an explicit SOLARPUNK_VERBOSE env var. Read here (before the host builds) so
    // the bootstrap logger's minimum level is right from the first line.
    private static bool ResolveVerbose(string[] args)
    {
        // Explicit env var shortcut (accepts 1/true/yes/on, case-insensitive).
        var env = Environment.GetEnvironmentVariable("SOLARPUNK_VERBOSE");
        if (IsTruthy(env)) return true;

        try
        {
            var config = new ConfigurationBuilder()
                .SetBasePath(AppContext.BaseDirectory)
                .AddJsonFile("appsettings.json", optional: true, reloadOnChange: false)
                .AddEnvironmentVariables()
                .AddCommandLine(args)
                .Build();
            // Bind the typed value so "true"/"false" parse correctly; default false.
            return config.GetValue("Solarpunk:Verbose", false);
        }
        catch
        {
            // Never let config-read trouble change the default off-state.
            return false;
        }
    }

    private static bool IsTruthy(string? v)
    {
        if (string.IsNullOrWhiteSpace(v)) return false;
        v = v.Trim();
        return v.Equals("1", StringComparison.Ordinal)
            || v.Equals("true", StringComparison.OrdinalIgnoreCase)
            || v.Equals("yes", StringComparison.OrdinalIgnoreCase)
            || v.Equals("on", StringComparison.OrdinalIgnoreCase);
    }

    private static void PrintStartupBanner()
    {
        var solarpunkVer = SolarpunkVersionInfo.SolarpunkVersion;
        var os = System.Runtime.InteropServices.RuntimeInformation.OSDescription;
        var dotnetVer = Environment.Version.ToString();
        var host = Environment.MachineName;

        Log.Information("==========================================================");
        Log.Information("  SundialServer v{Version}  (open-source Solarpunk dedicated host)", solarpunkVer);
        Log.Information("  https://github.com/HumanGenome/SundialServer");
        Log.Information("  Official hosting: https://www.survivalservers.com");
        Log.Information("----------------------------------------------------------");
        Log.Information("  host:    {Host}", host);
        Log.Information("  os:      {Os}", os);
        Log.Information("  runtime: .NET {DotNet}", dotnetVer);
        Log.Information("  sp:      build detected from host log (see [Solarpunk] lines)");
        Log.Information("==========================================================");
    }
}
