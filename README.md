# SundialServer

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![.NET 8](https://img.shields.io/badge/.NET-8.0-blueviolet.svg)](https://dotnet.microsoft.com/en-us/download/dotnet/8.0)
[![Platform](https://img.shields.io/badge/Platform-Windows_x64-blue.svg)](#requirements)
[![Game](https://img.shields.io/badge/Game-Solarpunk-darkgreen.svg)](https://store.steampowered.com/app/1805110/)

SundialServer is the open-source host supervisor for Sundial multiplayer in **Solarpunk**. It starts and watches the hosted game process, takes and restores save snapshots, exposes an admin HTTP API, answers Source A2S query, and runs Source RCON.

Players join with the [Sundial app](https://github.com/HumanGenome/Sundial). A playable host also needs Sundial's in-game runtime (UE4SS plus Sundial's server mods and the native plugin), which the **release zip bundles** as an `ue4ss-server\` folder — you copy its contents into the game's `Binaries\Win64` directory once. See [Installation](#installation) and [docs/ADMIN.md](docs/ADMIN.md#staging-the-runtime).

## Features

### 🖥 Host supervision
Starts Solarpunk headless with the Sundial runtime, monitors the game process, tracks the plugin heartbeat, and coordinates restarts.

### 💾 Save snapshots
Snapshots the world automatically on every game auto-save (when `SnapshotsEnabled` is on) and on admin trigger. Restore swaps the save directory atomically so a failed restore does not leave a half-written world, and a pre-restore snapshot is taken first so the operation is reversible.

### 📡 Source query
Answers standard Source A2S query on the configured query port so monitoring tools can read server name, map, player count, and the player list.

### 🛠 Source RCON
Runs a Source-compatible RCON listener with `help`, `status`, `players`, `ping`, `save snapshot`, `save list`, `say`, `announce`, and `motd`, plus slash commands registered by server mods.

### 🔐 Admin HTTP API
Exposes snapshot list/upload/download/restore, save import, health, player list, and mod manifest endpoints. Admin routes are HMAC-signed with a key derived from the RCON password.

### 🧩 Mod surface
Loads UE4SS Lua and C++ mods through the Sundial runtime layout, and publishes the server's mod manifest at `GET /api/v1/manifest` for the launcher to install on join.

## Requirements

- Windows 10/11 or Windows Server x64
- Solarpunk game files installed on the host machine (SundialServer launches them; it does not ship the game)
- Open/forwarded ports for gameplay, query, RCON, and admin HTTP as needed

Release builds are self-contained; a separate .NET install is not required for normal use.

## Installation

### Managed hosting
[SurvivalServers.com Solarpunk hosting](https://www.survivalservers.com/services/game_servers/solarpunk/?utm_source=github&utm_medium=readme_install&utm_campaign=sundialserver) ships the complete Sundial server runtime already installed and handles ports, updates, and panel integration.

### Self-host
1. Download `SundialServer-v<version>.zip` from the [latest release](https://github.com/HumanGenome/SundialServer/releases/latest). It is self-contained: `SolarpunkServer\` (the supervisor + `appsettings.json`) plus the in-game runtime under `ue4ss-server\`.
2. Extract it to a stable folder, such as `C:\Solarpunk\`.
3. Install the Solarpunk game files under the folder set as `GameInstallRoot` (default `C:\Solarpunk\game`) — copy your `steamapps\common\Solarpunk` folder there, or install with SteamCMD (app `1805110`). The server runs headless; no GPU is required.
4. Copy the **contents** of `SolarpunkServer\ue4ss-server\` into `<GameInstallRoot>\Solarpunk\Binaries\Win64\`. The supervisor launches the game but does not stage the runtime for you — see [docs/ADMIN.md](docs/ADMIN.md#staging-the-runtime).
5. Edit `SolarpunkServer\appsettings.json` (see below).
6. Open/forward the ports listed below.
7. Run `SolarpunkServer\SolarpunkServer.exe`.

Players connect with the Sundial app to `<host>:<GameplayPort>`.

> **Note:** the release zip is complete — it bundles the in-game runtime (UE4SS + Sundial's server mods + the native plugin) alongside the MIT-licensed supervisor. Without that runtime staged into the game's `Binaries\Win64`, the game comes up as a plain Solarpunk listen server with no password gate, chat, roster, or admin tools. Managed hosting includes the runtime and stages it for you.

## Server Settings

SundialServer reads `appsettings.json` (next to `SolarpunkServer.exe`) under the `Solarpunk` section.

| Setting | Default | Purpose |
|---|---:|---|
| `InstanceId` | `default` | Stable instance name used in logs, query rules, and API responses. |
| `ServerName` | empty | Public name shown in the launcher and Source query. Empty falls back to `Solarpunk - <InstanceId>`. |
| `GameInstallRoot` | `C:\Solarpunk\game` | Solarpunk install folder. The server launches the game headless from here. |
| `GameUserDir` | `C:\Solarpunk\userdir` | User directory used by the hosted game process; the live save lives under `Saved\SaveGames`. |
| `SaveDir` | `C:\Solarpunk\saves` | Snapshot zips and archived saves. |
| `GameplayPort` | `27015` | UDP port players join through Sundial. |
| `QueryPort` | `27017` | UDP Source A2S query port. |
| `RconPort` | `27018` | TCP Source RCON port. RCON is disabled when `RconPassword` is empty. |
| `HttpPort` | `27019` | TCP admin HTTP API port. Set to `0` to disable. |
| `RconPassword` | empty | Admin password for RCON; the HTTP API signing key is derived from it. Set this before exposing RCON or HTTP. |
| `SolarpunkAuthPassword` | empty | Join password enforced server-side for remote players. Empty means an open server. Also sets the password flag in Source query. |
| `MaxPlayers` | `4` | Slot count reported to the launcher and query clients. |
| `SnapshotsEnabled` | `true` | Auto-snapshot on every game auto-save. When `false`, only admin-triggered snapshots run. |
| `PluginHeartbeatTimeoutSeconds` | `30` | Seconds before SundialServer treats the game runtime as unresponsive. |
| `WorldName` | `World1` | World save slot. The world persists across restarts under this name. |
| `SaveIntervalSeconds` | `300` | Floor for forced world saves. The game's own autosave still runs. |
| `Mods` | empty | Mod manifest published at `GET /api/v1/manifest`: `Required`, `Recommended`, and `Blocked` lists. Re-read on edit; no restart needed. |

Keep the ports unique for each server instance. The standard layout is:

| Port | Protocol | Purpose |
|---:|---|---|
| `GameplayPort` | UDP | Solarpunk gameplay |
| `GameplayPort + 2` | UDP | Source A2S query |
| `GameplayPort + 3` | TCP | Source RCON |
| `GameplayPort + 4` | TCP | Admin HTTP API |

The launcher derives the RCON and admin HTTP ports as gameplay+3 and gameplay+4, so keep those offsets if you want the launcher's Console and world tools to work against your server. The query port is editable per-server in the launcher.

## Source Query Example

SundialServer answers standard Source A2S queries on `QueryPort`.

```powershell
py -m pip install python-a2s
@'
import a2s

address = ("127.0.0.1", 27017)
info = a2s.info(address)
players = a2s.players(address)

print(f"{info.server_name} - {info.player_count}/{info.max_players} on {info.map_name}")
for player in players:
    print(f"{player.name} {player.duration:.0f}s")
'@ | py -
```

The same port works with tools such as GameDig, LGSM monitors, and Discord status bots that support Source query.

## RCON

Connect to `RconPort` with the configured `RconPassword` (RCON is disabled while the password is empty).

```text
help
status
players
ping
save snapshot
save list
say <message>
announce <message>
motd [message]
```

Mod-registered slash commands also run over RCON, with or without the leading `/`. Restoring a snapshot is **not** an RCON command — use the launcher's World backups dialog or the HTTP API.

## Build From Source

```powershell
git clone https://github.com/HumanGenome/SundialServer.git
cd SundialServer
dotnet build Solarpunk.Server.sln -c Release
dotnet publish SolarpunkServer/SolarpunkServer.csproj -c Release -r win-x64 --self-contained true
```

Published output lands under `SolarpunkServer/bin/Release/net8.0/win-x64/publish/`.

To build the full distributable instead of just the supervisor:

```bash
UE4SS_RUNTIME_DIR=/path/to/ue4ss scripts/package-server.sh v<version>
```

That assembles the supervisor, `runtime/` (UE4SS settings and signatures), the
Lua mods from `server-mods/`, the native plugin from `native/SolarpunkPlugin/`,
and the UE4SS runtime binaries into the same `SundialServer-v<version>.zip`
layout the releases ship, and prints its sha256. The UE4SS runtime binaries and
the compiled plugin are not in this repo, so supply them or the script tells you
what is missing.

## Repository Layout

| Path | Contents |
|---|---|
| `SolarpunkServer/` | the supervisor host, services, and HTTP/query/RCON surfaces |
| `Solarpunk.*/` | protocol, persistence, RCON, and A2S query libraries |
| `server-mods/` | the UE4SS Lua mod stack loaded inside the game process |
| `native/SolarpunkPlugin/` | the C++ UE4SS plugin source |
| `runtime/` | UE4SS settings, AOB signatures, and the mod load list |
| `scripts/` | packaging and signature-verification tooling |
| `docs/`, `protocol/` | administration guides and wire-format contracts |

## Documentation

- [docs/ADMIN.md](docs/ADMIN.md) — settings, ports, RCON, the HTTP API, health, snapshots
- [docs/RUNTIME.md](docs/RUNTIME.md) — boot chain, world persistence, save identity, join auth, troubleshooting
- [docs/MODS.md](docs/MODS.md) — the mod stack, status files, writing your own host mod
- [runtime/README.md](runtime/README.md) — what the in-game runtime folder contains and how it is staged
- [protocol/](protocol/) — wire-format contracts (manifest, chat, map, ModKit, installer)

## Community Note

Sundial is a community project and is not affiliated with or endorsed by the developers of Solarpunk.

## Contributing

Issues and pull requests for SundialServer are welcome. For bug reports, include the SundialServer version, the Solarpunk game build, and relevant logs from `logs\` (one JSON object per line, rolled daily).

## License

MIT. See [LICENSE](LICENSE).

## Credits

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — Unreal Engine scripting and modding framework
