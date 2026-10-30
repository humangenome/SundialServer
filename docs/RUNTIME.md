# Sundial runtime

How a Sundial host boots, what each layer does, and what to look at when a stage
fails. Read [ADMIN.md](ADMIN.md) first for the settings and ports. Self-hosting on the
current Solarpunk version is not supported by the public package.

Solarpunk (Steam app `1805110`, Unreal Engine 5.7) ships no dedicated server.
Sundial runs the retail game headless as a listen host on the game's own Epic
Online Services networking (Solarpunk 1.3.0 and later), so players join with the
game's invite code and install nothing. A supervisor adds the pieces a dedicated
server is expected to have: Source query, RCON, an admin HTTP API.

## Boot chain

```
the host's launcher → SolarpunkServer.exe launch
  └─ starts <GameInstallRoot>\Solarpunk\Binaries\Win64\SolarpunkSteam-Win64-Shipping.exe suspended,
     with two DLLs queued to load before the game's own code:
       ├─ SolarpunkEosIdentity.dll   this server's own Epic device identity
       └─ ue4ss\UE4SS.dll
            └─ Mods\mods.txt → SolarpunkServerRuntime
                 ├─ SolarpunkModKit        _G.Solarpunk API surface
                 ├─ SolarpunkHost          world → HostGame → save handling
                 ├─ SolarpunkAuth          join password gate (ip path only)
                 ├─ SolarpunkRoster        roster.json
                 ├─ SolarpunkChat          chat fan-out + MOTD
                 └─ SolarpunkNoPhantomHost hides the host's own player
```

The game signs in to Epic about 3 seconds after it starts, before UE4SS mods could
load, which is why both DLLs are queued at process creation. `SolarpunkServer.exe`
then runs alongside the game as its supervisor (query, RCON, HTTP).

## Layer responsibilities

**SolarpunkServer.exe (.NET 8 supervisor).** Runs beside the game: Source A2S query, Source RCON,
the HMAC-signed admin HTTP API, the chat ring buffer and save snapshots, and the
`launch` verb above. It is self-contained: no separate .NET install.

**SolarpunkEosIdentity.dll.** Points the Epic SDK's credential store at one file
per server (`<GameUserDir>\ss_eos_identity.cred`, or the path in
`SP_EOS_IDENTITY_FILE`). Without it every server on a machine signs in as the same
Epic device and shares one peer-to-peer address.

**UE4SS.** `UE4SS-settings.ini` sets `EngineVersionOverride` to 5.7 and disables
the UObject array cache; `UE4SS_Signatures\` carries five PDB-derived AOB patterns
(`FName_Constructor`, `GNatives`, `GUObjectArray`, `GUObjectHashTables`,
`StaticConstructObject`). UE4SS's built-in scanner is wrong on 5.7, so these are
required.

**SolarpunkServerRuntime.** One UE4SS mod and one scheduler on the game thread;
it loads the other modules by `dofile` in a fixed order and publishes
`.solarpunk-runtime-status`.

**SolarpunkPlugin.dll.** The old direct-IP identity plugin. Never load it on
Solarpunk 1.3.0: the host crashes on the first join.

## Hosting and joining

`SolarpunkHost` calls the game's own `HostGame()`. The game then signs in to Epic,
passes its privilege check, creates the session, opens `/Game/Maps/MainLevel` and
shows an invite code: the
game log line `Setting invite code UI widget to "ABCDE"`. The code is new at every
start. Players choose Multiplayer, Join session, Enter Code; the game's
`RedpointEOSNetDriver` carries the connection over Epic's peer-to-peer network, so
the game port is not used for joining.

## World persistence

`BP_SkyGameInstance_C` exposes an FString property `WorldSaveName`.
`SolarpunkHost` sets it **before** calling `HostGame()`, so the game's save system
loads `<GameUserDir>\Saved\SaveGames\<WorldName>.sav` or creates a fresh world
under that name.

The game autosaves every 150 s of world time, to a slot file it names itself. The
host copies the newest slot into `<WorldName>.sav` every 15 seconds and keeps a
ledger of every save it wrote (`sundial-world-ledger.txt`). At the next start a
`.sav` whose content is not in the ledger is treated as an upload and becomes the
world (the previous world is kept in `_sundial_orphaned_saves\`), whatever its file
time says.

Two `appsettings.json` keys drive it:

| Key | Default | Effect |
|---|---|---|
| `WorldName` | `World1` | the world save slot |
| `SaveIntervalSeconds` | `300` | how often the host re-pins the world slot; the game saves itself every 150 s of world time |

Each instance needs its own `GameUserDir`; that is what keeps two servers on one
box from sharing a world.

### Saving before a stop

The game writes nothing when its process is ended, so a plain stop loses
everything since the last autosave (up to 150 s). Before you stop the server,
ask the host for a save:

1. Write `<token> save` to `SolarpunkServer\runtime.save-request` (any token
   of letters, digits, `-`, `_` or `.`).
2. Wait for `SolarpunkServer\runtime.save-done` to start with `<token> `.
   `saved` means the game logged a successful save and the world file holds it;
   `timeout`, `failed` or `skipped` (not in the game world) mean it did not.
   The answer comes within about 2 s, or after 12 s at most.
3. Stop the server.

Do not ask within about 20 s of the game's own autosave (its
`Saving to '<slot>' was successful` line in the game log): a save stacked on
an autosave once crashed the game's save code. If the game saved moments ago,
write `<token> mirror` instead, which copies that save into the world file
without saving again.

## Players and characters

Solarpunk keys each saved player by the player's own account id: an Epic id for
an Epic player, the Steam id for a Steam player. A character follows the account,
on any computer, across rejoins and restarts. A different account starts a new
character.

The server's own hidden player always takes the first saved record. In a world
uploaded from single player that record is the owner's character, so set
`"SeparateServerRecord": "on"`: the host then gives the server a record of its
own once per world, and the owner keeps their character.

## Join authentication

On an `eos` server the invite code is the way in. `SolarpunkAuthPassword` is not
enforced there: invite-code players cannot send it. The password gate (a token
in the player name on the old direct-IP path) applies to `"Transport": "ip"` only.

Kicks (bans, RCON `kick`, a wrong password): on 1.3.0 the game's session cannot
drop a player on the host's command (`GameSession:KickPlayer` is not callable), so
the player first gets the game's own return-to-menu message, and a player still
connected 3 seconds later loses their character and controller on the server.

`HeartbeatWatchdogService` exists so a passworded `ip` server can never end up
running open because the mod stack failed to load: if `.solarpunk-auth-status` is
not a fresh `ready=1` past the grace window, the supervisor stops the game. It does
nothing on an `eos` server.

## Roster, query, and the map

`SolarpunkRoster` scans `GameState` and writes `roster.json` (players plus live
X/Y/Z) every 5 seconds and on login and logout. That one file feeds the A2S player
list, `GET /api/v1/players` and `GET /api/v1/map/state`. Map state is marked
stale after `Map.StaleAfterMs` (default 10 s). Roster entries, RCON kicks and bans
are keyed by the player's account id, the Epic id the game keeps for an
invite-code player (`SkyGamePlayerState.SkyGameNativeId`), so two players with the
same name stay apart. A player without one (the old direct-IP path) is keyed by
character name, and a ban by such a name-based id never applies to a player who
has an account id.

## Troubleshooting

| Symptom | Look at |
|---|---|
| `/health` 503, `runtime_ready: false` | UE4SS did not load or a module failed. Check `UE4SS.log` in the game's `ue4ss` folder, `%APPDATA%\Solarpunk\SolarpunkServerRuntime.log` (the account the game runs under) and the `failed=` key in `.solarpunk-runtime-status`. |
| `/health` 503, `runtime_ready: true`, `host_ready: false` | The stack loaded but the world never came up. Check `SolarpunkServer\logs\SolarpunkHost.log`, `.solarpunk-host-status` `reason=`, and the game log for the Epic sign-in. |
| No invite code line in `sp-ue.log` | The world did not open: read the end of `sp-ue.log` and `SolarpunkServer\logs\SolarpunkHost.log`. |
| A returning player has a new character | They joined with a different Epic or Steam account. |
| Everything breaks right after a game update | The PDB-derived AOB signatures went stale. Re-derive them against the new build. |

Attach `SolarpunkServer\logs\solarpunk-<date>.log`, `SolarpunkServer\logs\SolarpunkHost.log`,
the other module logs in `%APPDATA%\Solarpunk\` and `<GameUserDir>\sp-ue.log` to any bug report.
