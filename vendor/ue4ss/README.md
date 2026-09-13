# Pinned UE4SS runtime

`UE4SS.dll` and `dwmapi.dll` are the upstream [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)
runtime binaries (MIT, `LICENSE` alongside them) that the server bundle ships
under `ue4ss-server/`. They are vendored here, byte-for-byte, and the release
workflow refuses to build if either hash moves.

## Why vendored rather than downloaded

Upstream publishes the build this project runs on under the moving
`experimental-latest` tag, and that tag is re-cut in place: the same asset name
serves different bytes over time. A pipeline that downloads at release time
therefore ships whatever the tag happens to point at that day, and a UE4SS core
change lands on every host at once with nothing between it and the fleet.

Measured on 2026-07-30: the previous runtime was `UE4SS.dll`
16,388,608 bytes, while `experimental-latest` was serving 16,519,168 bytes under
the identical asset name. Different core, same URL.

So the pin is the file, not the URL.

## Hashes

| File | sha256 | bytes |
|---|---|---:|
| `UE4SS.dll` | `2ad348bf2025bd26b2aa63b478d9813afbd4e656c9bcfb3fdf6752c4d285f298` | 16,519,168 |
| `dwmapi.dll` | `8afd615b5c33c34bb2822af01dfe862097a8a82e1a1bd7888268e6467f4e1627` | 71,680 |

The September 2026 update includes the upstream
[string-pool lifetime fix](https://github.com/UE4SS-RE/RE-UE4SS/commit/aa7241f4df57ed5c0ad75f31da628f2c0df06235).
The old cache kept references to temporary Lua strings; later lookups could
read freed memory. Keep the complete runtime settings: the abbreviated settings
file omitted configuration needed during initialization.

`.github/workflows/release.yml` carries the same two values and fails the
release on a mismatch.

## Moving the pin

Replace both files, update the table above and the two `UE4SS_*_SHA256` values
in the release workflow in the same commit, then validate a real host start
before tagging. A UE4SS core swap changes signature-scan behaviour and mod
loading; it is never a drive-by update.

`scripts/package-server.sh` picks this folder up automatically, so a local build
needs no `UE4SS_RUNTIME_DIR`.
