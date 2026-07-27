# Map v1

SundialServer tracks connected players and their in-world positions and serves a
live map page plus a machine-readable state endpoint.

## Producer

The `SolarpunkRoster` UE4SS host mod scans `GameState` and writes `roster.json`
next to `SolarpunkServer.exe` every 5 seconds, and on player login and logout.
That single file feeds three consumers: the Source A2S player list,
`GET /api/v1/players`, and the map state endpoint below.

`roster.json` fields consumed by the map projection: `unix_ms`,
`world.name`, and a `players` array whose entries carry `SolarpunkUserId`,
`DisplayName`, `X`, `Y`, `Z`.

## The page

```
GET /map/
```

Aliases: `/map` and `/map/index.html`. Serves a self-contained HTML page with
`Cache-Control: no-store`. Returns `404 {"error":"map disabled"}` when
`Solarpunk.Map.Enabled` is `false`.

The page is **always public when the map is enabled**, even if the state
endpoint is private. That is deliberate: a visitor gets a "map is private"
message instead of a page that silently fails to load data.

## State

```
GET /api/v1/map/state
```

Public when `Solarpunk.Map.Public` is `true` (community dashboards). Otherwise
it requires the standard HMAC signature (the Sundial app's path). Returns
`404 {"error":"map disabled"}` when the map is disabled, regardless of auth.

```json
{
  "unix_ms": 1785600000123,
  "stale": false,
  "world": "World1",
  "players": [
    { "id": "765611900123456789", "name": "Alice", "x": 1024.5, "y": -880.0, "z": 312.0, "biome": "" }
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `unix_ms` | int | Timestamp from `roster.json`, not request time. |
| `stale` | bool | `true` when `now - unix_ms` exceeds `Map.StaleAfterMs` (default 10000). |
| `world` | string | World save name. |
| `players[].id` | string | The synthetic per-character save identity. |
| `players[].name` | string | Character display name. |
| `players[].x/y/z` | number | World-space position. |
| `players[].biome` | string | Reserved; always empty in v1. |

A missing or unparseable `roster.json` yields an empty player list with
`stale: true` rather than an error — the map degrades instead of breaking.

## Configuration

```json
{
  "Solarpunk": {
    "Map": {
      "Enabled": true,
      "Public": false,
      "StaleAfterMs": 10000
    }
  }
}
```

`Public: true` exposes player positions to anyone who can reach the HTTP port.
Treat it as a deliberate choice, not a default.

## Coordinates

Positions are raw Unreal world-space units as reported by the game. v1 defines
no tile set, projection, or scale — the page renders points in that raw space.
Any consumer wanting a georeferenced overlay has to supply its own transform.
