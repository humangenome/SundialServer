# SundialServer admin guide

Raw controls for a self-hosted SundialServer. If you rent a hosted server, use
your host's panel instead; it drives the same settings.

## Server package layout

The release zip extracts to a single `SolarpunkServer\` folder:

```
SolarpunkServer\
├── SolarpunkServer.exe        the host supervisor (starts the game, RCON, A2S query, HTTP API)
├── appsettings.json           per-instance config
├── ue4ss-server\              the in-game runtime (UE4SS and the server mods)
│   ├── UE4SS.dll              UE4SS runtime (pinned build)
│   ├── UE4SS-settings.ini     EngineVersionOverride 5.7 + scan tuning
│   ├── UE4SS_Signatures\      5 PDB-derived AOB patterns for the current game build
│   ├── SolarpunkEosIdentity.dll  gives this server its own Epic device identity
│   ├── Mods\                  the Sundial server mod stack (see docs/MODS.md)
│   ├── dwmapi.dll             old UE4SS proxy loader (the direct-IP path)
│   └── SolarpunkPlugin.dll    old direct-IP plugin; never loaded on Solarpunk 1.3.0
├── logs\                      solarpunk-<date>.log, one JSON object per line, rolled daily
└── data\                      hmac.key and local supervisor state
```

`SolarpunkServer.exe` does **not** ship the game.

## Self-hosting

Self-hosting on the current Solarpunk version is not supported by the public package.
The settings, ports, RCON commands and HTTP API below describe how the server is
configured and controlled; a hosted server uses the same ones.

## Settings (`SolarpunkServer\appsettings.json`)

Everything lives under the top-level `Solarpunk` block. `Chat`, `Mods`, and
`Map` nest **inside** that block, not at the top level.

At minimum set:

- `InstanceId`: stable id for this instance; appears in logs, query rules and every API response
- `ServerName`: the name Source query reports (server lists, status bots)
- `GameInstallRoot`: where the Solarpunk game files live
- `GameUserDir`: the game's user folder (world, Engine.ini, game log)
- `Transport`: `eos` on Solarpunk 1.3.0, players join with the game's invite code. `ip` (the default when the key is missing) is the old direct-IP path and cannot open a world on Solarpunk 1.3.0
- `GameplayPort`: the base port; query, RCON and the HTTP API sit at +2, +3 and +4
- `RconPassword`: turns RCON on; the admin HTTP API signing key is derived from it
- `SolarpunkAuthPassword`: a join password for the `ip` path only. Invite-code players cannot send it, so an `eos` server does not enforce it: the code is the way in

Full setting table is in the [README](../README.md#server-settings).

Two settings are commonly missed:

- `MaxPlayers` is what query clients report. It is a display figure, not a hard
  engine limit.
- `PluginHeartbeatTimeoutSeconds` (default 30) sets how fresh the in-game status
  files must be for `/api/v1/health` (see below).

## Ports

| Offset | Default | Purpose | Proto |
|---|---|---|---|
| +0 | `GameplayPort` | the game's port pin (`ip` path: the join port) | UDP |
| +1 | `ControlPort` | local IPC identifier | none |
| +2 | `QueryPort` | Source A2S query | UDP |
| +3 | `RconPort` | Source RCON | TCP |
| +4 | `HttpPort` | admin HTTP API + live map | TCP |

On an `eos` server players join through Epic's peer-to-peer network with the
invite code, not through the game port, so nothing has to be forwarded for them.
Open the query port for server lists and status bots, and RCON or HTTP only if you
use them from another machine. The control port is a local IPC identifier and
needs no rule.

Run several instances on one box by spacing `GameplayPort` at least 5 apart. Each
instance needs its own `GameUserDir`; `SolarpunkEosIdentity.dll` then gives each one
its own Epic identity.

## RCON commands

SundialServer speaks Source RCON on `RconPort`. RCON is disabled while
`RconPassword` is empty.

| Command | Effect |
|---|---|
| `help` | list commands |
| `status` | server status |
| `players` | connected players, each with an id (the Epic account id for invite-code players) |
| `ping` | liveness |
| `save snapshot` | take a world snapshot |
| `save list` | list snapshots |
| `say <msg>` | broadcast on the system channel |
| `announce <msg>` | broadcast on the admin channel |
| `motd [msg]` | read or set the MOTD |
| `kick <name\|id>` | send a player off the server; one still connected 3 s later is removed by the server |
| `ban <name\|id> [reason]` | ban a player; a name must match one online player, and invite-code players are banned by their Epic account id |
| `unban <id>` | lift a ban (the id from `bans`) |
| `bans` | list bans |

A name with spaces goes in quotes: `kick "Player 1"`. When two players share a
name, use the id from `players`.

Mod-registered slash commands also run over RCON, with or without the leading
`/`. See [MODS.md](MODS.md).

Restoring a snapshot is **not** an RCON command: use
`POST /api/v1/snapshots/<id>/restore` on the HTTP API.

## Admin HTTP API

Public, no auth:

- `GET /api/v1/health`: liveness and the online decision
- `GET /api/v1/players`: connected players
- `GET /api/v1/manifest`: mod manifest ([spec](../protocol/manifest-v1.md))
- `GET /api/v1/chat/motd`: the message of the day ([spec](../protocol/chat-v1.md))
- `GET /map/`: the live map page ([spec](../protocol/map-v1.md))
- `GET /api/v1/map/state`: map state, public only when `Map.Public` is `true`

HMAC-signed:

- `GET /api/v1/info`
- `GET /api/v1/snapshots`, `POST /api/v1/snapshots`
- `GET /api/v1/snapshots/<id>/download`
- `POST /api/v1/snapshots/<id>/restore`
- `POST /api/v1/snapshots/import-restore`
- `GET /api/v1/chat/recent`
- `POST /api/v1/chat/say`, `POST /api/v1/chat/motd`
- `GET /api/v1/map/state` when the map is private

Signing scheme:

```
key       = per-instance HMAC key derived from RconPassword
canonical = METHOD + "\n" + path + "\n" + unix_ts + "\n" + sha256_hex(body)
headers   = X-Solarpunk-Timestamp: <unix seconds>
            X-Solarpunk-Signature: <hex HMAC_SHA256(key, canonical)>
            X-Solarpunk-Content-Sha256: <sha256_hex(body)>   (bodies over 64 KB)
```

The server rejects timestamps older than 5 minutes and tracks accepted
signatures so a captured request cannot be replayed inside that window.

A request is authenticated before its body is stored. Bodies up to 64 KB (every
JSON call) are read and checked as they are. A larger body, such as a snapshot
upload, must send `X-Solarpunk-Content-Sha256`: the signature is checked from the
headers first, then the body streams to a temp file and must hash to the declared
value. Without that header a body over 64 KB gets `428`, and a body of unknown
length (chunked, no header) gets `411`. `MaxUploadBytes` defaults to 2 GB and
overflow returns 413. One upload runs at a time (a second one gets `503`), and
public reads such as `/api/v1/health` have their own request slots.

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

If `ok` is false and `runtime_ready` is false, the UE4SS mod stack did not load:
check `logs\` and `UE4SS.log` in the game's `ue4ss` folder.

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
