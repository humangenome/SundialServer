# Mods on Sundial

Sundial loads its server mods through [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)
on the host: Lua mods in the UE4SS `Mods` folder, enabled through `mods.txt`.
Players need no mods: they join with the game's invite code.

The release also carries `SolarpunkPlugin.dll`, the native plugin of the old
direct-IP path. It is not loaded on Solarpunk 1.3.0 (it crashes the host on the
first join).

## Where mods live

Host mods live in the game's `Binaries\Win64\ue4ss\Mods\` folder, copied from the
release's `ue4ss-server\Mods`.

`mods.txt` lines are `<ModName> : 1` to enable, `: 0` to disable. Comment lines
start with `;`. Keep the file CRLF-terminated: UE4SS handles mixed line endings
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
| 2 | `SolarpunkHost` | world select and persistence, `HostGame`, uploads, the save before a stop |
| 3 | `SolarpunkAuth` | join password gate (the old direct-IP path only) |
| 4 | `SolarpunkRoster` | scans GameState, writes `roster.json` for A2S, the players API, and the map |
| 5 | `SolarpunkChat` | inbound chat fan-out, MOTD, join/leave broadcasts |
| 6 | `SolarpunkNoPhantomHost` | hides the host's own player and shows remote players' names |

**Do not also enable the feature mods directly in `mods.txt`.** UE4SS starts one
async event loop per enabled Lua mod, and double-loading the stack gives you two
of every hook.

No UE4SS sample mod (`CheatManagerEnablerMod`, `ConsoleCommandsMod`, `ConsoleEnablerMod`,
`Keybinds` and the rest) is switched on, and `scripts/verify-server-bundle.py` fails a
bundle that switches one on.

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

Per-mod logs land in `%APPDATA%\Solarpunk\<ModName>.log` (the account the game runs
under), except `SolarpunkHost.log`, which is in `SolarpunkServer\logs\`.

## Client mods

None. On Solarpunk 1.3.0 players join with the game's invite code and nothing
installed. `SolarpunkConnect`, the direct-IP join mod the retired Sundial app
installed, cannot join a 1.3.0 server ([installer-v1](../protocol/installer-v1.md)
describes that old path).

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
`Recommended`, and `Blocked` lists. The retired Sundial app read it before joining;
an invite-code server lists no required mods. The manifest is re-read from config
on every request, so a change costs no restart. Wire format:
[manifest-v1](../protocol/manifest-v1.md).

## Writing your own host mod

Match the shape of Sundial's mods: `<ModName>/Scripts/main.lua` plus an
`enabled.txt`, then add `<ModName> : 1` to `mods.txt`. Rules that matter:

- Resolve UObjects on the game thread (`Solarpunk.GameThread.Run`), never from
  the async loop directly.
- Never block the UE4SS async loop: a blocking call there stalls every other mod.
  Periodic work goes through the runtime's game-thread scheduler; searching the
  whole object list every tick costs world time (the host runs a fixed 30 fps step).
- Register HTTP endpoints under `/mod/` only; `Solarpunk.Http.RegisterEndpoint`
  rejects anything else.
- Write files atomically. The supervisor polls several of these paths and a
  half-written status file reads as a failure.

## Don't

- Don't post anti-cheat-evasion or game-piracy material in mod issues or PRs.
- Don't modify retail Solarpunk game files: keep changes in the UE4SS overlay
  so Steam's update path stays intact.
