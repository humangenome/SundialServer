using System.Security.Cryptography;
using SolarpunkServer.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace SolarpunkServer.Services;

/// <summary>
/// Loads or mints the per-instance HMAC key used to authenticate the named-pipe
/// IPC. Stored as 64-hex characters in <see cref="SolarpunkServerOptions.HmacKeyPath"/>.
/// Generated on first run with cryptographic-strength randomness.
/// </summary>
public sealed class HmacKeyService
{
    private readonly byte[] _key;

    public HmacKeyService(IOptions<SolarpunkServerOptions> options, ILogger<HmacKeyService> log)
    {
        var path = options.Value.HmacKeyPath;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);

        if (File.Exists(path))
        {
            var hex = File.ReadAllText(path).Trim();
            if (hex.Length != 64)
                throw new InvalidOperationException($"hmac key file {path} must be 64 hex characters, got {hex.Length}");
            _key = Convert.FromHexString(hex);
            log.LogInformation("Loaded HMAC key from {Path}", path);
        }
        else
        {
            _key = RandomNumberGenerator.GetBytes(32);
            File.WriteAllText(path, Convert.ToHexString(_key));
            log.LogWarning("Generated new HMAC key at {Path} — copy this to SolarpunkPlugin.dll instance config", path);
        }
    }

    public byte[] Key => _key;
}
