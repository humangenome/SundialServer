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

Measured on 2026-07-30: the runtime this project ships is `UE4SS.dll`
16,388,608 bytes, while `experimental-latest` was serving 16,519,168 bytes under
the identical asset name. Different core, same URL.

So the pin is the file, not the URL.

## Hashes

| File | sha256 | bytes |
|---|---|---:|
| `UE4SS.dll` | `09a06d70771938b5117d53f88934e701debb19a16a14ee1ac37d2f6481bdebdc` | 16,388,608 |
| `dwmapi.dll` | `aa8eeee6a86537febdb4f6e3ba6aba7f825534e3f50092f7cbb745365a52a3dd` | 61,952 |

`.github/workflows/release.yml` carries the same two values and fails the
release on a mismatch.

## Moving the pin

Replace both files, update the table above and the two `UE4SS_*_SHA256` values
in the release workflow in the same commit, then validate a real host start
before tagging. A UE4SS core swap changes signature-scan behaviour and mod
loading; it is never a drive-by update.

`scripts/package-server.sh` picks this folder up automatically, so a local build
needs no `UE4SS_RUNTIME_DIR`.
