# Chat v1

Solarpunk ships no native text chat, so SundialServer provides one: a
server-side ring buffer, an MOTD, admin broadcast verbs over RCON and HTTP, and
an ingest endpoint for in-game overlays.

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

## Reads — public

```
GET /api/v1/chat/recent?since=<unix_ms>&limit=<n>
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
GET /api/v1/chat/motd
```

```json
{ "instance": "solarpunk-local", "msg": "Welcome." }
```

Both are public on purpose. The only thing that reaches the ring buffer is
content already broadcast to every joined player, so a public read leaks
nothing extra. The in-game overlay runs inside the player's game process and has
no access to `RconPassword`, so requiring HMAC would mean shipping the admin
secret to every client. If private channels are ever added, the public surface
stays admin-broadcast-only and a separate authed endpoint carries them.

## Player ingest — public, rate-limited

```
POST /api/v1/chat/player
Content-Type: application/json

{ "sender": "Alice", "msg": "hello" }
```

Used by in-game overlays. The server forces `channel` to `player` and `target`
to `all`; a client cannot claim a system or admin channel. Per-IP rate limiting
applies.

| Status | Meaning |
|---|---|
| `200` | `{ "ok": true, "ts": <unix_ms> }` |
| `400` | Missing `msg`, or invalid JSON. |
| `413` | Body over 2 KB. |
| `429` | Rate limited. |

Request bodies are capped at 2 KB and the message body itself is truncated to
512 bytes.

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
emits join and leave notices. The client-side overlay that renders a typed input
box is a **preview** and is not enabled by default.
