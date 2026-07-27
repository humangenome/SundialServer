# Sundial wire protocols

The wire-format contracts between SundialServer, the Sundial app, the UE4SS mod
stack, and third-party tools. Implementations should be forward-compatible with
new optional fields: ignore what you don't recognise rather than failing.

Everything here is served from the admin HTTP port (`GameplayPort + 4` by
default). Ports and auth are covered in [../docs/ADMIN.md](../docs/ADMIN.md).

| File | Contract |
|---|---|
| [manifest-v1.md](manifest-v1.md) | `GET /api/v1/manifest` — the mod manifest the app reads before joining |
| [chat-v1.md](chat-v1.md) | chat feed, MOTD, and the admin broadcast verbs |
| [map-v1.md](map-v1.md) | live map + player roster |
| [modkit-v1.md](modkit-v1.md) | the `Solarpunk.*` Lua ModKit API for host mods |
| [installer-v1.md](installer-v1.md) | client-side UE4SS overlay layout and the join handoff |

## Versioning

Each contract carries its own integer version in the payload
(`manifest_version`, `version`) or in the API surface (`Solarpunk.ModKit.Version`).
A version bump means a breaking change. Additive optional fields do not bump it.

`X-Solarpunk-Instance` is present on every HTTP response and carries the
server's `InstanceId`.
