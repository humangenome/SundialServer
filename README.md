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

SundialServer runs a **Solarpunk dedicated server** on Windows. Players join with the game's own invite code: in Solarpunk's main menu choose Join session, type the server's 5-letter code and press Done. The code changes each time the server starts.

Project page: [Sundial](https://github.com/HumanGenome/Sundial).

## What it does

### 💾 Saved before every stop
Before a stop, the server has the game save the world, so the minutes since its last autosave are kept. Whatever stops the server asks for it with one file: see [Saving before a stop](docs/RUNTIME.md#saving-before-a-stop).

### 🗂 World backups
Takes a snapshot of the world on request, and on every game autosave when `SnapshotsEnabled` is on. The HTTP API puts an earlier snapshot back, taking a snapshot of the running world first.

### 📡 Shows up in server lists
Answers Source server query, so server lists, GameDig, LGSM monitors and Discord status bots can read the server's name, player count and player list.

### 🖥 Server console
Source RCON: see who is online, kick and ban players, take and list world snapshots. `players` lists each player with an id: the player's Epic account id for invite-code players. Kick and ban by that id when two players share a name; a name with spaces goes in quotes (`kick "Player 1"`). Every command is in [docs/ADMIN.md](docs/ADMIN.md).

### 🔐 Admin API
An HTTP API for health, players and snapshots. Admin routes are signed with a key derived from the RCON password, a request is checked before its body is stored, and `AllowedReaders` limits which addresses can reach it.

## What you need

Self-hosting on the current Solarpunk version is not supported by the public package. The ports and settings below are how a hosted server is set up.

- Windows 10, 11 or Server, 64-bit
- Solarpunk's game files on the machine (SundialServer does not ship the game)

## Ports

| Port | Protocol | Purpose |
|---:|---|---|
| `GameplayPort` | UDP | the game's port setting; players do not join through it |
| `GameplayPort + 2` | UDP | Source server query: open it for server lists |
| `GameplayPort + 3` | TCP | RCON: open it only to use RCON from another machine |
| `GameplayPort + 4` | TCP | admin HTTP API: same |

Players join through Epic's peer-to-peer network with the invite code, so nothing has to be forwarded for them.

## Settings

`SolarpunkServer\appsettings.json`, under the `Solarpunk` section.

| Setting | Default | Purpose |
|---|---|---|
| `ServerName` | empty | the name Source query reports |
| `InstanceId` | `default` | stable id in logs, query rules and API answers |
| `Transport` | `ip` | `eos` on Solarpunk 1.3.0: players join with the invite code. `ip` is the old direct-IP path and cannot open a world on 1.3.0 |
| `GameplayPort` | `27015` | the base port; query, RCON and HTTP are +2, +3 and +4 |
| `RconPassword` | empty | turns RCON on; the HTTP API's signing key comes from it |
| `AllowedReaders` | empty | addresses allowed to reach the HTTP API; empty means anyone, and this machine is always allowed |
| `MaxPlayers` | `4` | the slot count Source query reports |
| `WorldName` | `World1` | the world's save name |
| `SeparateServerRecord` | `off` | `on` for a world uploaded from single player, so its owner keeps their character |
| `SnapshotsEnabled` | `true` | a snapshot on every game autosave |

Every setting, the HTTP API and the health check: [docs/ADMIN.md](docs/ADMIN.md).

## Rent a server

[SurvivalServers.com Solarpunk hosting](https://www.survivalservers.com/services/game_servers/solarpunk/?utm_source=github&utm_medium=readme_install&utm_campaign=sundialserver) runs SundialServer for you and shows the invite code in its control panel.

## Build from source

```powershell
git clone https://github.com/HumanGenome/SundialServer.git
cd SundialServer
dotnet build Solarpunk.Server.sln -c Release
dotnet test Solarpunk.Server.sln -c Release --no-build
```

`scripts/package-server.sh v<version>` builds the full release zip: the supervisor, the in-game runtime and the server mods.

## Releases

CI cuts every release from a tag, never by hand, and checks the zip before and after publishing. Release notes are on the [releases page](https://github.com/HumanGenome/SundialServer/releases).

## Documentation

- [docs/ADMIN.md](docs/ADMIN.md): settings, ports, RCON, the HTTP API, health, snapshots
- [docs/RUNTIME.md](docs/RUNTIME.md): how the host boots, hosting and joining, the world, saving before a stop, troubleshooting
- [docs/MODS.md](docs/MODS.md): the mod stack and its status files
- [protocol/](protocol/): wire formats

## Contributing

Issues and pull requests are welcome; [CONTRIBUTING.md](CONTRIBUTING.md) lists what to include. Questions about a server you rent go to your host.

## Community note

Sundial is a community project and is not affiliated with or endorsed by the developers of Solarpunk.

## License

MIT. See [LICENSE](LICENSE).

## Credits

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS): the Unreal Engine scripting framework the server mods run on
