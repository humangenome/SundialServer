# Mods on Sundial

Sundial loads mods through [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) on both
the host and the client. There are two layers:

1. **Lua mods** in the UE4SS `Mods` folder, enabled through `mods.txt`.
2. **A native C++ plugin** (`SolarpunkPlugin.dll`) that supplies the identity
   hook and the named-pipe IPC channel back to `SolarpunkServer.exe`.

## Where mods live

| Side | Path | Loaded by |
|---|---|---|
| Host | `<GameInstallRoot>\Solarpunk\Binaries\Win64\Mods\` (staged from `ue4ss-server\Mods`) | host UE4SS, `mods.txt` |
| Client | the player's `...\Solarpunk\Binaries\Win64\Mods\` | client UE4SS, `mods.txt`, installed by the Sundial app |

`mods.txt` lines are `<ModName> : 1` to enable, `: 0` to disable. Comment lines
start with `;`. Keep the file CRLF-terminated — UE4SS handles mixed line endings
inconsistently.

## The host mod stack

Production enables exactly **one** Sundial mod in `mods.txt`:

```
SolarpunkServerRuntime : 1
```

`SolarpunkServerRuntime` is the orchestrator. It `dofile`-loads the feature
modules from sibling folders in a fixed, boot-critical order, then publishes a
status file the supervisor polls:

| Order | Module | Job |
|---|---|---|
| 1 | `SolarpunkModKit` | populates the `_G.Solarpunk` API surface consumer mods use |
| 2 | `SolarpunkHost` | transport swap, world select and persistence, `HostGame`, per-player save keying |
| 3 | `SolarpunkAuth` | server-side join password gate |
| 4 | `SolarpunkRoster` | scans GameState, writes `roster.json` for A2S, the players API, and the map |
| 5 | `SolarpunkChat` | inbound chat fan-out, MOTD, join/leave broadcasts |

**Do not also enable the feature mods directly in `mods.txt`.** UE4SS starts one
async event loop per enabled Lua mod, and double-loading the stack gives you two
of every hook.

UE4SS's own `CheatManagerEnablerMod`, `ConsoleCommandsMod`, `ConsoleEnablerMod`,
and `Keybinds` stay enabled; `Keybinds` loads last by UE4SS convention.

## Status files

Each layer writes a `key=value` status file into the `SolarpunkServer\` folder.
The supervisor reads them; they are also the fastest way to diagnose a boot
failure by hand.

| File | Written by | Keys |
|---|---|---|
| `.solarpunk-runtime-status` | `SolarpunkServerRuntime` | `ready`, `mods`, `failed`, `updated`, `reason` |
| `.solarpunk-host-status` | `SolarpunkHost` | `hosting`, `world`, `updated`, `reason` |
| `.solarpunk-auth-status` | `SolarpunkAuth` | `ready`, `passwordConfigured`, `updated`, `reason` |

`SolarpunkServerRuntime` pre-invalidates `.solarpunk-auth-status` to `ready=0` at
boot, so a stale `ready=1` from a previous process can never be trusted.

Per-mod logs land in `%APPDATA%\Solarpunk\<ModName>.log`.

## The client mod

The Sundial app installs one client mod, `SolarpunkConnect`. It reads the
connect target the app writes and issues the stock Unreal `open <target>` once a
`PlayerController` exists. See [installer-v1](../protocol/installer-v1.md).

## The `Solarpunk.*` ModKit API

`SolarpunkModKit` publishes `_G.Solarpunk` for third-party host mods. Guard on
the version before using it:

```lua
local Solarpunk = _G.Solarpunk
if not Solarpunk or not Solarpunk.ModKit or Solarpunk.ModKit.Version < 1 then
    return
end
```

Surface: `Solarpunk.Log`, `Solarpunk.Paths`, `Solarpunk.GameThread`,
`Solarpunk.Commands`, `Solarpunk.Players`, `Solarpunk.Events`, `Solarpunk.Chat`,
`Solarpunk.Http`. Full contract in [modkit-v1](../protocol/modkit-v1.md).

## Server-published mod manifest

A server advertises what it wants players to run via `GET /api/v1/manifest`,
configured under the `Solarpunk.Mods` block in `appsettings.json` as `Required`,
`Recommended`, and `Blocked` lists. The Sundial app reads it before joining and
installs or warns accordingly. The manifest is re-read from config on every
request, so adding a recommended mod costs no restart. Wire format:
[manifest-v1](../protocol/manifest-v1.md).

## Writing your own host mod

Match the shape of Sundial's mods: `<ModName>/Scripts/main.lua` plus an
`enabled.txt`, then add `<ModName> : 1` to `mods.txt`. Rules that matter:

- Resolve UObjects on the game thread (`Solarpunk.GameThread.Run`), never from
  the async loop directly.
- Never block the UE4SS async loop — the host's tick rate drops hard when no
  players are connected, and a blocking call there stalls every other mod.
- Register HTTP endpoints under `/mod/` only; `Solarpunk.Http.RegisterEndpoint`
  rejects anything else.
- Write files atomically. The supervisor polls several of these paths and a
  half-written status file reads as a failure.

## Don't

- Don't post anti-cheat-evasion or game-piracy material in mod issues or PRs.
- Don't modify retail Solarpunk game files — keep changes in the UE4SS overlay
  so Steam's update path stays intact.
