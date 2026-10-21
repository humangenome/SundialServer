# Chat v1

Solarpunk ships no native text chat, so SundialServer provides one: a
server-side ring buffer, an MOTD, and admin broadcast verbs over RCON and HTTP.

## Message shape

```json
{
  "ts": 1785600000123,
  "sender": "Admin",
  "target": "all",
  "channel": "system",
  "msg": "Restarting in 5 minutes.",
  "color": null
}
```

| Field | Type | Notes |
|---|---|---|
| `ts` | int | Unix milliseconds. Also the cursor for incremental reads. |
| `sender` | string | Display name of the originator. |
| `target` | string | `all`, or a specific player. Defaults to `all`. |
| `channel` | string | One of `system`, `admin`, `player`, `motd`. Anything else normalises to `system`. |
| `msg` | string | The message body. |
| `color` | string \| null | Optional client-side render hint. |

The buffer holds `Solarpunk.Chat.RingBufferSize` messages (default 200).

## Reads

```
GET /api/v1/chat/recent?since=<unix_ms>&limit=<n>      (HMAC required)
```

`since` defaults to `0`, `limit` to `100`. Returns messages with `ts > since`,
oldest first. Poll with the highest `ts` you have seen to tail the feed.

```json
{
  "version": 1,
  "instance": "solarpunk-local",
  "now_ms": 1785600001000,
  "messages": [ … ]
}
```

```
GET /api/v1/chat/motd      (public)
```

```json
{ "instance": "solarpunk-local", "msg": "Welcome." }
```

The MOTD is public: every joining player is shown it anyway. The recent feed is
signed like the other admin routes, because the ring buffer also carries join and
leave lines with player names.

## Admin writes — HMAC required

```
POST /api/v1/chat/say
{ "msg": "...", "channel": "admin", "color": null, "sender": "Admin" }
```

`channel` defaults to `system`. Returns `{ "ok": true, "ts": <unix_ms> }`, or
`400` when `msg` is missing.

```
POST /api/v1/chat/motd
{ "msg": "..." }
```

Sets the MOTD. Returns `{ "ok": true }`, `400` on a missing body, `500` if the
MOTD could not be persisted.

Both use the standard HMAC scheme documented in
[../docs/ADMIN.md](../docs/ADMIN.md#admin-http-api).

## RCON equivalents

| RCON | Channel |
|---|---|
| `say <msg>` | `system` |
| `announce <msg>` | `admin` |
| `motd [msg]` | reads or sets the MOTD |

## In-game delivery

Delivery to players is handled by the `SolarpunkChat` host mod, which fans
inbound messages out through the game's stock `ClientMessage` path and also
emits join and leave notices. There is no player typing path: players cannot post
chat through the server's HTTP API.
