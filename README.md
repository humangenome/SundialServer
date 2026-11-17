<p align="center">
  <img src="https://raw.githubusercontent.com/HumanGenome/Sundial/main/docs/img/sundial-logo.png" alt="Sundial" width="400">
</p>

<p align="center">
  <a href="#what-you-need"><img src="https://img.shields.io/badge/Platform-Windows_x64-blue.svg" alt="Platform"></a>
  <a href="https://store.steampowered.com/app/1805110/"><img src="https://img.shields.io/badge/Game-Solarpunk-darkgreen.svg" alt="Game"></a>
  <a href="https://github.com/HumanGenome/Sundial#do-players-need-to-install-anything"><img src="https://img.shields.io/badge/Players_install-nothing-brightgreen.svg" alt="Players install nothing"></a>
  <a href="https://dotnet.microsoft.com/en-us/download/dotnet/10.0"><img src="https://img.shields.io/badge/.NET-10.0-blueviolet.svg" alt=".NET 10"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License"></a>
</p>

# SundialServer

Solarpunk has no dedicated server. SundialServer runs a **Solarpunk dedicated server** on Windows. Players join with the game's own invite code: in Solarpunk's main menu choose Join session, type the server's 5-letter code and press Done. The code changes each time the server starts.

Project page: [Sundial](https://github.com/HumanGenome/Sundial).

## What it does

### Saved before every stop
Before a stop, the server has the game save the world, so the minutes since its last autosave are kept. To get this save, whatever stops the server writes one file first: see [Saving before a stop](docs/RUNTIME.md#saving-before-a-stop).

### World backups
The server backs up the world on request, and after every game autosave when `SnapshotsEnabled` is on (the default when you run it yourself). The admin API restores an earlier backup and backs up the last saved world first.

### Shows up in server lists
Answers Source server query, so server lists, GameDig, LGSM monitors and Discord status bots can read the server's name, player count and player list.

### Server console
RCON: see who's online, kick and ban players, and take and list world backups. When two players share a name, kick or ban by the id that `players` shows. Every command is in [docs/ADMIN.md](docs/ADMIN.md).

### Admin API
An HTTP API for server health, the player list and world backups. Admin requests are signed with a key made from the RCON password, and you can limit which addresses reach it.

## What you need

The SundialServer download doesn't support hosting your own server on the current Solarpunk version. The ports and settings below show how a hosted server is set up.

- Windows 10, 11 or Server, 64-bit
- Solarpunk's game files on the machine

## Ports

| Port | Protocol | Purpose |
|---:|---|---|
| `GameplayPort` | UDP | the game's port setting. Players don't join through it |
| `GameplayPort + 2` | UDP | Source server query: open it for server lists |
| `GameplayPort + 3` | TCP | RCON: open it only to use RCON from another machine |
| `GameplayPort + 4` | TCP | admin HTTP API: open it only to use the API from another machine |

Players join through Epic's peer-to-peer network with the invite code, so nothing has to be forwarded for them.

## Settings

`SolarpunkServer\appsettings.json`, under the `Solarpunk` section.

| Setting | Default | Purpose |
|---|---|---|
| `ServerName` | empty | the name Source query reports |
| `InstanceId` | `default` | stable id in logs, query rules and API answers |
| `Transport` | `ip` | `eos` on Solarpunk 1.3.0: players join with the invite code. `ip` is the old Join by IP mode and can't open a world on 1.3.0 |
| `GameplayPort` | `27015` | the base port; query, RCON and HTTP are +2, +3 and +4 |
| `RconPassword` | empty | turns RCON on. The HTTP API's signing key comes from it |
| `AllowedReaders` | empty | addresses allowed to reach the HTTP API. Empty means anyone, and this machine is always allowed |
| `MaxPlayers` | `4` | the slot count Source query reports |
| `WorldName` | `World1` | the world's save name |
| `SeparateServerRecord` | `off` | `on` for a world uploaded from single player, so its owner keeps their character |
| `SnapshotsEnabled` | `true` | a world backup after every game autosave |

Every setting, the HTTP API and the health check: [docs/ADMIN.md](docs/ADMIN.md).

## Rent a server

[SurvivalServers.com](https://www.survivalservers.com/services/game_servers/solarpunk/?utm_source=github&utm_medium=readme_install&utm_campaign=sundialserver) runs Solarpunk servers with SundialServer installed. Your server's invite code is in Command Center.

## Build from source

```powershell
git clone https://github.com/HumanGenome/SundialServer.git
cd SundialServer
dotnet build Solarpunk.Server.sln -c Release
dotnet test Solarpunk.Server.sln -c Release --no-build
```

`scripts/package-server.sh v<version>` builds the full release zip: the supervisor, the in-game runtime and the server mods.

## Releases

GitHub Actions builds every release from a tag, never by hand, and checks the zip before and after it's published. Release notes are on the [releases page](https://github.com/HumanGenome/SundialServer/releases).

## Documentation

- [docs/ADMIN.md](docs/ADMIN.md): settings, ports, RCON, the HTTP API, health, world backups
- [docs/RUNTIME.md](docs/RUNTIME.md): how the host boots, hosting and joining, the world, saving before a stop, troubleshooting
- [docs/MODS.md](docs/MODS.md): the mod stack and its status files
- [protocol/](protocol/): wire formats

## Contributing

Bugs: [open an issue](https://github.com/HumanGenome/SundialServer/issues). Pull requests are welcome, and [CONTRIBUTING.md](CONTRIBUTING.md) lists what to include. Questions about a server you rent go to your host.

## Community note

Sundial is a community project and is not affiliated with or endorsed by the developers of Solarpunk.

## License

MIT. See [LICENSE](LICENSE).

## Credits

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS): the Unreal Engine scripting framework the server mods run on
