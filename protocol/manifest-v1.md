# Mod Manifest v1

SundialServer publishes a JSON manifest at `GET /api/v1/manifest`. The Sundial
app fetches it before joining and uses it to install required and recommended
UE4SS mods on the player's side, and to surface a blocked-mods list so the
player knows what the server won't tolerate.

## Endpoint

```
GET /api/v1/manifest
Host: <server_host>:<http_port>
```

**Public — no auth.** A player deciding whether to join has to read this before
they have any credentials, so HMAC is intentionally not enforced. Integrity
rests on the per-mod `sha256` field.

Cheap and idempotent. Clients may poll it.

## Response

```
200 OK
Content-Type: application/json
X-Solarpunk-Instance: <instance_id>

{
  "manifest_version": 1,
  "instance": "solarpunk-local",
  "server_name": "Solarpunk Dedicated Server",
  "solarpunk_version": "0.1.50",
  "generated_unix": 1785600000,

  "required": [
    {
      "id": "example.chat",
      "name": "Example Chat Overlay",
      "version": "1.0.0",
      "url": "https://example.invalid/mods/ExampleChat-1.0.0.zip",
      "sha256": "abc123…",
      "size_bytes": 47104,
      "install_root": "ue4ss/Mods/ExampleChat",
      "notes": "Required for in-game text chat."
    }
  ],

  "recommended": [],

  "blocked": [
    { "id": "example.cheatpanel", "reason": "Server policy: no client-side cheat consoles." }
  ]
}
```

### Top-level fields

| Field | Type | Required | Notes |
|---|---|:---:|---|
| `manifest_version` | int | yes | Wire-format version. `1` in this document. |
| `instance` | string | yes | Mirrors `X-Solarpunk-Instance`. |
| `server_name` | string | yes | Falls back to `Solarpunk - <instance>` when unset. |
| `solarpunk_version` | string | yes | SundialServer version on the host. |
| `generated_unix` | int | yes | Seconds since epoch at request time. |
| `required` | array | yes | Mods the app should install before joining. |
| `recommended` | array | yes | Mods the app should offer but not enforce. |
| `blocked` | array | yes | Mods the admin explicitly does not want loaded. |

Empty arrays are valid. All three empty means "no opinion, vanilla join".

### Entry fields (`required`, `recommended`)

| Field | Type | Required | Notes |
|---|---|:---:|---|
| `id` | string | yes | Stable identifier, `<namespace>.<name>`, lowercase ASCII. |
| `name` | string | yes | Human-readable name for the app's Mods tab. |
| `version` | string | yes | Free-form, typically SemVer. Drives upgrade decisions. |
| `url` | string | yes | Direct download URL or a landing page. |
| `sha256` | string \| null | no | Hex SHA256 of the zip. `null` means unverifiable. |
| `size_bytes` | int \| null | no | Optional sanity check. |
| `install_root` | string | yes | Relative path the zip extracts to. |
| `notes` | string | no | Shown in the app. |

### Entry fields (`blocked`)

| Field | Type | Required | Notes |
|---|---|:---:|---|
| `id` | string | yes | Same `<namespace>.<name>` format. |
| `reason` | string | yes | Shown to the player so the policy is legible. |

`blocked` is informational in v1. The app displays the list and can warn when a
blocked mod is already installed; it does not remove anything, and the server
does not reject the join over it. Enforcement needs a client-to-server
mod-report message that does not exist in v1.

## Server-side configuration

The three lists come straight from `appsettings.json`:

```json
{
  "Solarpunk": {
    "Mods": {
      "Required":    [ ],
      "Recommended": [ ],
      "Blocked":     [ ]
    }
  }
}
```

Values pass through verbatim; the server adds the top-level metadata at request
time. A server with no `Mods` section returns all three lists empty.

### Hot reload

The `Mods` section is read fresh from configuration on **every** request, so an
admin adding a recommended mod does not restart the server or cost anyone a
session.

## Client behaviour (informative)

1. On Connect, `GET /api/v1/manifest`.
2. On failure, continue the join with a warning — a transient manifest fetch
   failure must not block a player.
3. For each `required` entry not already installed at that version: download,
   verify `sha256` when non-null (mismatch refuses), extract to `install_root`.
   Extraction failure aborts the join.
4. For each `recommended` entry: same flow, but ask first.
5. For each installed `blocked` entry: warn, do not auto-remove.

## Errors

| Status | Meaning |
|---|---|
| `200` | Normal response. |
| `500` | Internal error generating the manifest. |
| `503` | Too many requests already in flight; `Retry-After: 5`. |

## Future work

- Signed manifests, so integrity does not rest solely on per-entry `sha256`.
- A mod-report message so `required` and `blocked` become enforceable at join.
- Compatibility constraints (`min_solarpunk_version`, `requires`, `conflicts`).
