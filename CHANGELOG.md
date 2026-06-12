# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versioning is [SemVer](https://semver.org/).

## [0.1.4] - 2026-06-12

### Fixed

- The A2S (Source query) player list and the HTTP players endpoint now report
  each player's chosen character name. The roster written by the in-game mod
  stack is authoritative whenever it has entries; log-derived fallback entries
  no longer merge in alongside it, and a machine-shaped session identity is
  never published as a player name on the fallback path either.
- The log-tail name cleaner strips the name-channel auth token, so a server
  password can never appear in a published player list.

### Security

- Bumped MessagePack to 3.1.7 (GHSA-hv8m-jj95-wg3x).

## [0.1.3] - 2026-06-11

### Fixed

- The in-game PLAYERS list and player nameplates now show each player's chosen
  character name instead of a per-session machine identity, and the listen
  host no longer appears as a phantom entry in the player list. The server
  rewrites the replicated name table the in-game UI reads from, so the correct
  names show on every connected client.

## [0.1.2] - 2026-06-11

### Fixed

- Re-derived the UE4SS `GUObjectArray` AOB signature for the current Solarpunk
  game build. The previous signature broke when the game's binary layout
  shifted on a game update; the new signature wildcards relocatable operands so
  a pure data-layout shift no longer breaks the runtime. A `verify-signatures`
  helper checks all five signatures against a new game build and proposes
  replacements when one goes stale.
- The connect transport re-asserts the player's chosen character name for the
  session, so the name keys saves and shows in the roster instead of a
  per-session machine identity.

## [0.1.1] - 2026-06-10

### Fixed

- Moved the in-game runtime load into the compiled supervisor, so Windows
  Defender script scanning no longer blocks server startup. The server runs
  with antivirus fully enabled, no exclusions for scripts required.

## [0.1.0] - 2026-06-10

### Added

- Initial release: host supervisor, the UE4SS server-mod stack (host,
  auth, roster, chat), Source A2S query, Source RCON, admin HTTP API, save
  snapshots with atomic restore, and a server-side join password.
