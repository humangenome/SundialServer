# Overlay Installer v1

How the Sundial app lays out the client-side UE4SS overlay alongside a player's
retail Solarpunk, and how the join is handed off to the game. This is the
contract a third-party client would have to satisfy to join a Sundial server.

## Client overlay layout

Everything is installed into the game's Win64 directory, next to the shipping
executable:

```
...\steamapps\common\Solarpunk\Solarpunk\Binaries\Win64\
├── SolarpunkSteam-Win64-Shipping.exe   (retail, untouched)
├── steam_appid.txt                     "1805110"
├── UE4SS.dll
├── dwmapi.dll                          UE4SS proxy — Windows auto-loads it
├── UE4SS-settings.ini                  EngineVersionOverride 5.7 + scan tuning
├── UE4SS_Signatures\                   5 PDB-derived AOB patterns
└── Mods\
    ├── mods.txt
    └── SolarpunkConnect\
        ├── enabled.txt
        └── Scripts\main.lua
```

Installation is idempotent and version-marked, so relaunching does not re-copy
an unchanged pack.

The five signature files (`FName_Constructor`, `GNatives`, `GUObjectArray`,
`GUObjectHashTables`, `StaticConstructObject`) are derived from the game's
shipped PDB. UE4SS's built-in scanner is wrong on 5.7 — the overrides are
required, and they go stale when the game's binary layout shifts on an update.

## Transport config

Before launch the client writes:

```
%LOCALAPPDATA%\Solarpunk\Saved\Config\Windows\Engine.ini
```

The load-bearing line is:

```ini
[OnlineSubsystemSteam]
bEnabled=false
```

That deregisters SteamSockets so `IpNetDriver` binds a real UDP socket.
Alongside it: `OnlineSubsystem` set to `Null`, `IpNetDriver`
`NetDriverDefinitions`, extended connection timeouts, and rate caps.

Unreal rewrites this file on a clean exit, so it must be re-applied on **every**
launch. A write failure has to fail the connect — the join cannot work without
it.

## Identity handoff

```
%APPDATA%\Solarpunk\client-identity.txt
```

One line: `STEAM <steamid64> <charHash8>`, or `STEAM <steamid64>` when no
character is selected.

The synthetic id is derived from the character name and must match the host's
formula exactly:

```
"765611900" + (crc32(lowercase(character_name)) mod 1e9)
```

## Join handoff

```
%APPDATA%\Solarpunk\connect-target.txt
```

One line:

```
<host>:<port>?Name=<character>?SPJoin=<nonce>
```

On a password-protected server the character segment carries the token:

```
<host>:<port>?Name=<character>__SPPW__<password>?SPJoin=<nonce>
```

Sequence:

1. Write `client-identity.txt`.
2. Clear any stale `connect-target.txt`.
3. Launch the game, having dropped `steam_appid.txt` beside the exe.
4. Wait for UE4SS to come up.
5. Publish `connect-target.txt`.

`SolarpunkConnect` polls for that file and issues the stock Unreal console
`open <line>` once a `PlayerController` exists.

`SPJoin` changes on every Connect action. It exists so an already-running client
can be told to retry the same server and character — without a changing nonce
the mod cannot distinguish a repeat request from the one it already consumed.

## Server-side expectations

- Gameplay UDP on the base port; A2S on +2, RCON on +3, admin HTTP on +4.
- `GET /api/v1/health` for reachability and the online decision.
- `GET /api/v1/manifest` before joining ([manifest-v1](manifest-v1.md)).
- `GET /api/v1/players` for the roster panel.

All of these degrade gracefully: a client that cannot reach the HTTP port should
still be able to join if the gameplay port is reachable.

## Auto-update

The Sundial app updates itself from an ed25519-signed manifest. The signature
covers `version + "\n" + sha256 + "\n" + package_url`, verified against a public
key embedded in the app; an unsigned or badly signed manifest is rejected
outright. Packages are hashed as a stream, and a package that fails its
structural or version checks is suppressed for later background polls of that
same manifest version, with one manual retry available from Settings.
