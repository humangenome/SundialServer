# Contributing to SundialServer

Short and to the point.

## Reporting bugs

Open an issue. Include:

- SundialServer version (`beacon_version` from `GET /api/v1/health`, or `status` over RCON)
- Solarpunk build ID
- Steps to reproduce
- Server log excerpt (`logs/solarpunk-*.log` — one JSON object per line, rolled daily)
- Whether anyone else can reproduce on a clean server

If your issue is about specific managed hosting (panel, billing, support), please contact your host directly. SundialServer's GitHub issues are for the open-source server itself.

## Feature requests

Open an issue. Describe the use case, not the implementation. If you're proposing a wire-format or protocol change, point at the affected file(s) in `src/shared/Sundial.Protocol/`.

## Pull requests

- Branch from `main`, name `feat/<short-slug>` or `fix/<short-slug>`
- Keep commits short and focused — one logical change per commit
- Match existing code style
- For new dependencies, justify in the PR description and pin the version in `Directory.Packages.props`
- Run the test suite locally before opening the PR (`dotnet test SundialServer.sln -c Release`)

## Code of conduct

Be civil. Be technical. Don't post game-piracy or anti-cheat-evasion material in issues or PRs.
