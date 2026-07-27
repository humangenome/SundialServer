# ModKit v1

`SolarpunkModKit` publishes a global `_G.Solarpunk` table that third-party host
mods integrate against: logging, paths, game-thread work, slash commands, the
player list, events, chat, and mod HTTP endpoints.

`SolarpunkServerRuntime` loads the ModKit **first**, before any feature module,
so anything in the stack can rely on it.

## Guarding

Always version-guard before touching the API:

```lua
local Solarpunk = _G.Solarpunk
if not Solarpunk or not Solarpunk.ModKit or Solarpunk.ModKit.Version < 1 then
    return
end
```

`Solarpunk.ModKit` is `{ Version = 1, BuildTag = "v1.0" }`. `Version` is an
integer and only bumps on a breaking change.

## `Solarpunk.Paths`

| Field | Meaning |
|---|---|
| `InstanceRoot` | the instance's root directory |
| `SolarpunkServerDir` | the `SolarpunkServer\` folder (where `appsettings.json` and the status files live) |
| `LogDir` | `%APPDATA%\Solarpunk` |
| `ModsRoot` | the UE4SS `Mods` directory |

Resolution mirrors `SolarpunkRoster`'s locator, so it works regardless of the
process's current directory.

## `Solarpunk.Log`

```lua
local log = Solarpunk.Log.For("MyMod")   -- appends to <LogDir>\MyMod.log
log("hello")
```

Lines are timestamped and CRLF-terminated.

## `Solarpunk.GameThread`

```lua
Solarpunk.GameThread.Run(function() … end)
Solarpunk.GameThread.IsOnGameThread()      -- always false in v1
```

Resolve and touch UObjects inside `Run`. UE4SS exposes no reliable way to test
whether you are already on the game thread, so `IsOnGameThread` returns `false`
conservatively — do not branch on it.

## `Solarpunk.Commands`

```lua
Solarpunk.Commands.Register("weather", handler, {
    admin_only = true,
    help  = "Set the weather",
    usage = "/weather <clear|rain>",
})
Solarpunk.Commands.Unregister("weather")
Solarpunk.Commands.List()          -- sorted { name, help, usage, admin_only }
Solarpunk.Commands.Dispatch(name, ctx)
```

`Register` raises if `name` is not a non-empty string or `handler` is not a
function. Names are stored lowercase. `admin_only` defaults to **false**;
`usage` defaults to `/<name>`.

The handler receives a context table: `{ args = {…}, raw = "<full line>", caller = {…} }`.
`Dispatch` returns `nil, "unknown_command"` for an unregistered name,
`nil, "admin_required"` when `admin_only` is set and `ctx.caller.is_admin` is
not truthy, and `nil, "handler_error"` if the handler raises (the error is
logged, never propagated).

Registered commands are also reachable over RCON, with or without the leading
slash.

## `Solarpunk.Players`

Reads the roster the `SolarpunkRoster` mod publishes.

```lua
Solarpunk.Players.List()            -- array of player records
Solarpunk.Players.GetByName(name)   -- case-insensitive
Solarpunk.Players.GetById(id)
Solarpunk.Players.GetBySteamId(id)
Solarpunk.Players.Count()
```

Player record:

| Field | Type | Notes |
|---|---|---|
| `id` | string | Composite save identity. |
| `name` | string | Character display name. |
| `steam_id` | string | Numeric prefix of `id`, or `""`. |
| `character_id` | string | Hex suffix of `id`, or `""` when the id is bare digits. |
| `joined_unix_ms` | number | |
| `last_seen_unix_ms` | number | |
| `ping_ms` | number | |

Every accessor refreshes from the roster file first, so a call is a file read.
Cache the result inside a tick rather than calling `List()` in a loop.

## `Solarpunk.Events`

```lua
local h = Solarpunk.Events.OnPlayerJoin(function(player) … end)
Solarpunk.Events.OnPlayerLeave(function(player) … end)
Solarpunk.Events.OnTick(1000, function() … end)     -- interval in ms
Solarpunk.Events.OnServerReady(function() … end)
Solarpunk.Events.Unsubscribe(h)
```

Every subscribe returns an opaque handle for `Unsubscribe`. Join and leave are
derived by diffing the roster on the ModKit's 250 ms poll, so they fire within
one poll of the underlying event, not synchronously with it. `OnServerReady`
fires once, when the first player is observed.

## `Solarpunk.Chat`

```lua
Solarpunk.Chat.Send(target, msg, opts)   -- target "all" or a player
Solarpunk.Chat.Broadcast(msg, opts)      -- Send("all", msg, opts)
Solarpunk.Chat.OnMessage(function(m) … end)
```

Outbound messages land in the supervisor's chat ring buffer and are fanned out
in-game by `SolarpunkChat`. Message shape is [chat-v1](chat-v1.md).

## `Solarpunk.Http`

```lua
Solarpunk.Http.RegisterEndpoint("/mod/myfeature", handler, { admin_only = true })
```

Paths **must** start with `/mod/`; anything else raises. `admin_only` defaults
to **true** — pass `admin_only = false` explicitly to publish a public endpoint.
Registrations are flushed to a descriptor file the supervisor reads.

## Rules for consumer mods

- Never block the UE4SS async loop. Host tick rate drops hard with no players
  connected, and one blocking call stalls every other mod in the stack.
- Do UObject work inside `Solarpunk.GameThread.Run`.
- Write files atomically. The supervisor polls several of these paths and a
  half-written file reads as a failure.
- Do not enable the Sundial feature mods directly in `mods.txt` — the runtime
  orchestrator loads them.
