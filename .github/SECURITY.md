# Security Policy

## Reporting a vulnerability

If you've found a security issue in Sundial (SundialServer, the server mod stack, the native plugin, the launcher, or the admin HTTP API), please **do not** open a public GitHub issue.

Open a private security advisory at https://github.com/HumanGenome/SundialServer/security/advisories/new — that's the preferred channel.

Include:
- A description of the vulnerability
- Steps to reproduce
- Affected component (supervisor / server mods / plugin / launcher / API)
- SundialServer version (`solarpunk_version` from `GET /api/v1/health`, or `status` over RCON)
- Whether the issue is currently being exploited

We aim to acknowledge reports within 72 hours and provide a triage update within 7 days.

## Scope

In scope:
- Remote code execution or unauthenticated takeover of `SolarpunkServer.exe`
- Authentication bypass on the join password gate, RCON, or the admin HTTP API
- HMAC signature forgery or replay against the admin HTTP API
- Injection through the SolarpunkServer named-pipe IPC channel
- A connected client causing arbitrary host file writes through the save or snapshot paths
- Privilege escalation through the UE4SS mod stack or the native plugin

Out of scope:
- Vulnerabilities in the hardware host or hosting panel (report those to your hosting provider)
- Vulnerabilities in retail Solarpunk itself (report to the game's publisher)
- Vulnerabilities in third-party mods running on SundialServer
- Anti-cheat and cheating concerns — Sundial does not provide anti-cheat
- Missing code signing on release binaries (known, tracked in the README)

## Disclosure

Report privately, give us a chance to ship a fix, then we credit you in the release notes unless you'd rather stay anonymous.
