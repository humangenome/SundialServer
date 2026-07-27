# Sundial runtime

How a Sundial host actually boots, what each layer is responsible for, and what
to look at when a stage fails. Read [ADMIN.md](ADMIN.md) first for the settings
and ports.

Solarpunk (Steam app `1805110`, Unreal Engine 5.7) ships no dedicated server.
Sundial runs the retail game headless as a listen host, swaps its transport to
plain UE `IpNetDriver`, and wraps it in a supervisor that adds the pieces a
dedicated server is expected to have.

## Boot chain

```
SolarpunkServer.exe
  └─ launches <GameInstallRoot>\Solarpunk\Binaries\Win64\SolarpunkSteam-Win64-Shipping.exe
       └─ Windows loads dwmapi.dll (UE4SS proxy)
            └─ UE4SS.dll
                 └─ mods.txt → SolarpunkServerRuntime
                      ├─ SolarpunkModKit    _G.Solarpunk API surface
                      ├─ SolarpunkHost      transport swap → world → HostGame → save keying
                      ├─ SolarpunkAuth      join password gate
                      ├─ SolarpunkRoster    roster.json
                      └─ SolarpunkChat      chat fan-out + MOTD
                 └─ SolarpunkPlugin.dll → named-pipe IPC back to SolarpunkServer.exe
```

The supervisor also probes for `Binaries\Win64\Solarpunk-Win64-Shipping.exe` and
the non-nested `Binaries\Win64\` layout, in that order, so a build rename does
not break the launch.

## Layer responsibilities

**SolarpunkServer.exe (.NET 8 supervisor).** Owns the game process lifecycle,
Source A2S query, Source RCON, the HMAC-signed admin HTTP API, the chat ring
buffer, save snapshots and atomic restore, and the fail-closed auth watchdog.
It is self-contained — no separate .NET install required.

**UE4SS.** Loaded through the `dwmapi.dll` proxy. `UE4SS-settings.ini` sets
`EngineVersionOverride` to 5.7 and disables the UObject array cache;
`UE4SS_Signatures\` carries five PDB-derived AOB patterns (`FName_Constructor`,
`GNatives`, `GUObjectArray`, `GUObjectHashTables`, `StaticConstructObject`).
UE4SS's built-in scanner is wrong on 5.7 — these overrides are required, not
optional tuning.

**SolarpunkServerRuntime.** One UE4SS mod, one async event loop, five modules
loaded by `dofile` in a fixed order. Publishes `.solarpunk-runtime-status`.

**SolarpunkPlugin.dll.** Native identity hook plus the named-pipe client that
heartbeats to the supervisor and carries the player table.

## World persistence

`BP_SkyGameInstance_C` exposes an FString property `WorldSaveName`.
`SolarpunkHost` sets it **before** calling `HostGame()`, so the game's save
system either loads
`%LOCALAPPDATA%\Solarpunk\Saved\SaveGames\<WorldSaveName>.sav` or creates a
fresh world under that name. The result is a stable named world that survives
restarts.

Two `appsettings.json` keys drive it:

| Key | Default | Effect |
|---|---|---|
| `WorldName` | `World1` | the world save slot |
| `SaveIntervalSeconds` | `300` | floor for forced `SaveToDisk`; the game's own autosave still runs |

Per-instance isolation comes from launching each instance with its own
`LOCALAPPDATA`, which is what keeps two servers on one box from sharing a world.

## Player identity and save shards

The client is the source of the save key, provided up front on the travel URL.
Rewriting the parameter from a Blueprint hook does not reach the BP VM, and
reissuing the load late resets inventory ownership mid-session, so the key has
to arrive with the join.

```
synthetic id = "765611900" + (crc32(lowercase(character_name)) mod 1e9)
```

The Sundial app writes the same value into
`%APPDATA%\Solarpunk\client-identity.txt` and appends `?Name=<character>` to the
travel URL. Each character name therefore maps to one stable save shard, and a
player with three characters keeps three separate sets of progress on the same
world. An invalid or unrecognised remote load key fails closed rather than
falling back to a shared shard.

## Join authentication

The engine's `K2_PostLogin` does **not** fire for remote `IpNetDriver` clients on
this build — only for the listen host's local player. Remote joins run through
the game's own login path, so the gate hooks that instead.

The client's `?Password=` option is also unreadable from Lua on this build:
FString *properties* on the connection reflect as null UObjects, and no UFunction
returns the per-connection options. The one inbound channel the client controls
that Lua can read is the player **name**, via `GetPlayerName`.

So a passworded server is joined as:

```
open <ip>:<port>?Name=<character>__SPPW__<password>
```

`SolarpunkAuth` splits on the `__SPPW__` delimiter and compares the token to
`SolarpunkAuthPassword`; a mismatch or a missing token is a kick. Everything
downstream — save keying, roster, chat — strips the delimiter first, so the
password never reaches a save key or a published player name. The listen host
itself has no `NetConnection` and is positively detected and exempt.

An open server sends no token at all.

## Fail-closed auth watchdog

`HeartbeatWatchdogService` exists so a passworded server can never end up running
open because the mod stack silently failed to load. If `SolarpunkAuthPassword` is
set but `.solarpunk-auth-status` is not publishing a fresh `ready=1` past the
grace window, the supervisor stops the game rather than leaving it reachable.

`SolarpunkServerRuntime` pre-invalidates that status file at boot, so a stale
`ready=1` written by a previous process can never satisfy the watchdog.

If your server keeps stopping shortly after start and the log says FAIL-CLOSED,
the gate is not loading — that is a UE4SS or mod-stack problem, not a password
problem.

## Transport

The host swaps to plain UE `IpNetDriver`. On the client side the Sundial app
writes an `Engine.ini` before launch; the load-bearing line is
`[OnlineSubsystemSteam] bEnabled=false`, which deregisters SteamSockets so
`IpNetDriver` binds a real UDP socket. Without it the client never reaches the
host no matter what the address says. See
[installer-v1](../protocol/installer-v1.md).

## Roster, query, and the map

`SolarpunkRoster` scans `GameState` and writes `roster.json` (players plus live
X/Y/Z) every 5 seconds and on login/logout. That one file feeds three surfaces:
the A2S player list, `GET /api/v1/players`, and `GET /api/v1/map/state`. Map
state is marked stale after `Map.StaleAfterMs` (default 10s).

## Troubleshooting

| Symptom | Look at |
|---|---|
| `/health` 503, `runtime_ready: false` | UE4SS did not load or a module failed. Check `%APPDATA%\Solarpunk\SolarpunkServerRuntime.log` and the `failed=` key in `.solarpunk-runtime-status`. |
| `/health` 503, `runtime_ready: true`, `host_ready: false` | The stack loaded but the world never came up. Check `SolarpunkHost.log` and `.solarpunk-host-status` `reason=`. |
| Server stops itself, log says FAIL-CLOSED | `SolarpunkAuth` is not publishing a fresh ready status. UE4SS bootstrap, `mods.txt` ordering, or a mod load error. |
| Players connect but land on separate progress | Character name mismatch — the save key is derived from the lowercase name. |
| Empty A2S player list while players are in-game | `roster.json` is not being written. Check `SolarpunkRoster.log`. |
| Everything breaks right after a game update | The PDB-derived AOB signatures went stale. Re-derive them against the new build. |

Attach `logs\solarpunk-<date>.log` and the relevant `%APPDATA%\Solarpunk\*.log`
to any bug report.
