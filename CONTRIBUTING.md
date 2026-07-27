# Contributing to SundialServer

Short and to the point.

## Reporting bugs

Open an issue. Include:

- SundialServer version (`solarpunk_version` from `GET /api/v1/health`, or `status` over RCON)
- Solarpunk build ID
- Steps to reproduce
- Server log excerpt (`logs\solarpunk-<date>.log` — one JSON object per line, rolled daily)
- The relevant mod log from `%APPDATA%\Solarpunk\` when the problem is in the in-game runtime
- Whether anyone else can reproduce on a clean server

Set `Serilog:MinimumLevel` to `Debug` before capturing logs for a boot or join failure — that turns on the per-request HTTP trace and the full `/health` decision breakdown.

If your issue is about specific managed hosting (panel, billing, support), please contact your host directly. SundialServer's GitHub issues are for the open-source server itself.

## Feature requests

Open an issue. Describe the use case, not the implementation. If you're proposing a wire-format change, point at the affected file in [`protocol/`](protocol/).

## Pull requests

- Branch from `main`, name `feat/<short-slug>` or `fix/<short-slug>`
- Keep commits short and focused — one logical change per commit
- Match existing code style
- For new dependencies, justify in the PR description and pin the version in `Directory.Packages.props`
- Build clean before opening the PR: `dotnet build Solarpunk.Server.sln -c Release`

Changes to the UE4SS mod stack under `server-mods/` need a note in the PR describing how you validated them against a live host — a Lua mod that fails to load takes the whole runtime down with it.

## Code of conduct

Be civil. Be technical. Don't post game-piracy or anti-cheat-evasion material in issues or PRs.
