# SundialServer admin guide

Raw controls for a self-hosted SundialServer. Managed-hosting customers should
use their host's panel instead — it drives the same settings.

## Server package layout

The release zip extracts to a single `SolarpunkServer\` folder:

```
SolarpunkServer\
├── SolarpunkServer.exe        the host supervisor (RCON, A2S query, HTTP API, snapshots)
├── appsettings.json           per-instance config
├── ue4ss-server\              the in-game runtime — see "Staging the runtime" below
│   ├── UE4SS.dll              UE4SS runtime (pinned build)
│   ├── dwmapi.dll             UE4SS proxy loader
│   ├── UE4SS-settings.ini     EngineVersionOverride 5.7 + scan tuning
│   ├── UE4SS_Signatures\      5 PDB-derived AOB patterns for the current game build
│   ├── SolarpunkPlugin.dll    native identity/IPC plugin
│   └── Mods\                  the Sundial server mod stack (see docs/MODS.md)
├── logs\                      solarpunk-<date>.log, one JSON object per line, rolled daily
└── data\                      hmac.key and local supervisor state
```

`SolarpunkServer.exe` does **not** ship the game. Install Solarpunk separately
under the folder named by `GameInstallRoot`.

## Staging the runtime

The supervisor launches the game; it does **not** copy `ue4ss-server\` into the
game folder for you. Copy the **contents** of `ue4ss-server\` into the game's
Win64 directory before the first start:

```
<GameInstallRoot>\Solarpunk\Binaries\Win64\
├── UE4SS.dll
├── dwmapi.dll
├── UE4SS-settings.ini
├── SolarpunkPlugin.dll
├── UE4SS_Signatures\
└── Mods\
```

Windows auto-loads UE4SS through the `dwmapi.dll` proxy when the game starts
from that directory. Re-copy after any game update that replaces files in
`Binaries\Win64`. If `GET /api/v1/health` comes back with `runtime_ready: false`,
this step is the first thing to re-check.

Managed hosting does this staging for you.

## Settings (`SolarpunkServer\appsettings.json`)

Everything lives under the top-level `Solarpunk` block. `Chat`, `Mods`, and
`Map` nest **inside** that block, not at the top level.

At minimum set:

- `InstanceId` — stable id for this instance; appears in logs, query rules, and every API response
- `ServerName` — the public name shown in the launcher and Source query
- `GameInstallRoot` — where the Solarpunk game files live
- `GameplayPort` — the join port; the launcher derives RCON and HTTP from it
- `RconPassword` — required for RCON, and the admin HTTP API signing key is derived from it
- `SolarpunkAuthPassword` — the server-side join password (empty means an open server)

Full setting table is in the [README](../README.md#server-settings).

Two settings are commonly missed:

- `MaxPlayers` is what the launcher and query clients report. It is a display
  and admission figure, not a hard engine limit.
- `PluginHeartbeatTimeoutSeconds` (default 30) is how long the supervisor waits
  before treating the in-game runtime as unresponsive.

## Ports

| Offset | Default | Purpose | Proto |
|---|---|---|---|
| +0 | `GameplayPort` | Solarpunk gameplay — the join port | UDP |
| +1 | `ControlPort` | local IPC identifier | — |
| +2 | `QueryPort` | Source A2S query | UDP |
| +3 | `RconPort` | Source RCON | TCP |
| +4 | `HttpPort` | admin HTTP API + live map | TCP |

Open or forward every externally reachable port (+0, +2, +3, +4). The control
port is a local IPC identifier and needs no firewall rule. The gameplay UDP
port needs a Windows Defender inbound allow rule or players cannot reach the
listen socket.

The launcher derives RCON as gameplay+3 and admin HTTP as gameplay+4, so keep
those offsets if you want the launcher's Console, Mods, and World tools to work
against your server. The query port is editable per-server in the launcher.

Run several instances on one box by spacing `GameplayPort` at least 5 apart.

## RCON commands

SundialServer speaks Source RCON on `RconPort`. RCON is disabled while
`RconPassword` is empty.

| Command | Effect |
|---|---|
| `help` | list commands |
| `status` | server status |
| `players` | connected players |
| `ping` | liveness |
| `save snapshot` | take a world snapshot |
| `save list` | list saved worlds |
| `say <msg>` | broadcast on the system channel |
| `announce <msg>` | broadcast on the admin channel |
| `motd [msg]` | read or set the MOTD |
| `ban <player\|id> [reason]` | ban a player |
| `unban <id>` | lift a ban |
| `bans` | list bans |

Mod-registered slash commands also run over RCON, with or without the leading
`/`. See [MODS.md](MODS.md).

Restoring a snapshot is **not** an RCON command — use the launcher's World
backups dialog or `POST /api/v1/snapshots/<id>/restore` on the HTTP API.

## Admin HTTP API

Public, no auth:

- `GET /api/v1/health` — liveness and the online decision
- `GET /api/v1/players` — connected players
- `GET /api/v1/manifest` — mod manifest ([spec](../protocol/manifest-v1.md))
- `GET /api/v1/chat/recent`, `GET /api/v1/chat/motd` — chat plane reads ([spec](../protocol/chat-v1.md))
- `POST /api/v1/chat/player` — chat ingest from in-game overlays
- `GET /map/` — the live map page ([spec](../protocol/map-v1.md))
- `GET /api/v1/map/state` — map state, public only when `Map.Public` is `true`

HMAC-signed:

- `GET /api/v1/info`
- `GET /api/v1/snapshots`, `POST /api/v1/snapshots`
- `GET /api/v1/snapshots/<id>/download`
- `POST /api/v1/snapshots/<id>/restore`
- `POST /api/v1/snapshots/import-restore`
- `POST /api/v1/chat/say`, `POST /api/v1/chat/motd`
- `GET /api/v1/map/state` when the map is private

Signing scheme:

```
key       = per-instance HMAC key derived from RconPassword
canonical = METHOD + "\n" + path + "\n" + unix_ts + "\n" + sha256_hex(body)
headers   = X-Solarpunk-Timestamp: <unix seconds>
            X-Solarpunk-Signature: <hex HMAC_SHA256(key, canonical)>
```

The server rejects timestamps older than 5 minutes and tracks accepted
signatures so a captured request cannot be replayed inside that window. Upload
bodies stream to a temp file with chunked SHA256 — there is no full-body buffer.
`MaxUploadBytes` defaults to 2 GB and overflow returns 413.

Every response carries `X-Solarpunk-Instance`.

## Health and the online decision

`GET /api/v1/health` returns `200` with `ok: true` only when all of these hold:

- the game process is alive (when `GamePidFile` is configured)
- `.solarpunk-runtime-status` reports `ready` and is fresh
- `.solarpunk-host-status` reports `hosting` and is fresh

Otherwise it returns `503` with the individual flags (`runtime_ready`,
`runtime_status_fresh`, `host_ready`, `host_status_fresh`, `plugin_connected`,
`plugin_heartbeat_fresh`, `game_process_alive`, `runtime_reason`) so you can see
which stage failed. Freshness is `max(60s, PluginHeartbeatTimeoutSeconds * 3)`.

If `ok` is false and `runtime_ready` is false, the UE4SS mod stack did not load
— check `logs\` and the UE4SS log next to the game exe.

## Snapshots

With `SnapshotsEnabled: true` (the default) the supervisor snapshots the world
on every game auto-save, plus on admin trigger. Restore swaps the save directory
atomically, and takes a pre-restore snapshot first, so a failed restore never
leaves a half-written world and the operation stays reversible.

## Server query

SundialServer answers standard Source A2S on `QueryPort`, so GameDig, LGSM
monitors, Discord status bots, and server-list sites all work unmodified. The
player list reports each player's chosen character name.

## Logs

`logs\solarpunk-<date>.log`, one JSON object per line, rolled daily. Set
`Serilog:MinimumLevel` to `Debug` for the per-request HTTP trace and the full
`/health` decision breakdown. Attach these to any bug report.
