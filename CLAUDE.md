# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A hardened Docker setup for running Claude Code itself, launched per-project on
demand. It is not an application codebase — the "product" is the `cc-container`
CLI script plus the Docker image/compose configs it drives. `plrep/` and
`workspace/` are empty scratch/mount directories, not source.

## Commands

```bash
./cc-container setup                          # one-time: build image, create auth volume, log in
./cc-container launch <dev-dir> [session-name] [--new] [--env-file <path>]  # start or attach to a session
./cc-container list                             # show running sessions
./cc-container stop <session-name>              # stop and remove a session
./cc-container network <session-name> <docker-network-name>  # attach a running session to another network
```

There is no build/lint/test suite in this repo — it's shell scripts and Docker
config. Validate changes by actually running `./cc-container setup` and
`./cc-container launch <some-dir>` and confirming a session comes up and can
run `claude`.

## Architecture

- **`cc-container`** — single entry point (bash). Each subcommand (`setup`,
  `launch`, `list`, `stop`, `network`) shells out to `docker compose` with a
  per-session project name (`claude-<session-name>`), so every session is its
  own isolated Compose project (own containers, network, ports), all sharing
  one login volume. `launch` auto-picks free host ports starting at
  3000/5173/8080/8000 (incrementing per concurrent session), resumes the
  session's last `claude` conversation via `--continue` unless `--new` is
  passed, and re-attaches instead of restarting if the session's container
  is already up (in which case `--env-file` is ignored — env vars are fixed
  at container creation, so changing them requires `stop` + relaunch).
  `--env-file <path>` sets `SESSION_ENV_FILE`, consumed by
  `docker-compose.yml`'s `env_file:` directive to inject secrets as
  container env vars without ever bind-mounting the file into /workspace.
- **`Dockerfile`** — Node 20 slim image with Claude Code installed globally.
  Builds a non-root `claude` user with UID/GID passed in as build args
  (`USER_UID`/`USER_GID`, set from the host user by `cc-container setup`/
  `launch`) so bind-mounted project files come out host-owned, not owned by
  an arbitrary container UID.
- **`entrypoint.sh`** — container always starts as root (only to get
  `NET_ADMIN`/`NET_RAW` for firewall setup), runs `init-firewall.sh`, fixes
  ownership of the persisted auth volume, then uses `gosu` to drop to the
  non-root `claude` user permanently for the actual process. There is no
  `sudo` back to root from that point.
- **`init-firewall.sh`** — outbound firewall via `iptables`, two modes.
  Default (`FIREWALL_MODE=open` or unset): any host is reachable on ports
  80/443 only (web browsing, search grounding, arbitrary APIs), every other
  port is dropped. `FIREWALL_MODE=strict` switches to the old default-deny
  behavior — only an explicit allowlist of domains (Anthropic API/
  claude.ai, npm/PyPI/GitHub by default, resolved to IPs at container
  start) is permitted on 80/443, extended per-session via
  `EXTRA_ALLOWED_DOMAINS`. In either mode, `EXTRA_ALLOWED_PORTS` opens
  specific additional ports to any destination on demand (e.g. a project
  DB or SSH). It's DNS-snapshot/port-based, not a content-inspecting proxy.
- **`docker-compose.yml`** — the containment posture: `cap_drop: ALL` with
  only `NET_ADMIN`/`NET_RAW` (firewall), `SETUID`/`SETGID` (for `gosu`), and
  `CHOWN` (for fixing auth volume ownership) added back, `no-new-privileges`,
  and `mem_limit`/`pids_limit` caps. The container filesystem is writable but
  ephemeral (overlay layer is discarded on `docker compose down`); only
  `/workspace` and the `claude-config` auth volume persist across sessions.
  The `claude-config` volume (external, `claude-code-auth`) is what makes
  login shared across all sessions while everything else stays per-session.
  The dev dir is bind-mounted (and `working_dir` set) to
  `/workspace/${SESSION_NAME}`, not plain `/workspace` — Claude Code keys a
  session's resumable conversation history (inside the shared `claude-config`
  volume) off the container's absolute cwd, so every session needs a distinct
  cwd or `claude --continue` resumes whichever session's conversation was most
  recently active, not the one you're actually attached to.
- **`project-docker-compose.yml`** — reference example for embedding a
  `cc-container` service directly into a project's own `docker-compose.yml`
  (e.g. alongside a `db` service), so the session can reach project services
  by Compose service name on the shared default network. This is the
  recommended way to give a session access to a project's own backing
  services, as opposed to `cc-container network` (attaching a running
  session's container to another Compose project's network after the fact,
  which doesn't persist across restarts).

## Key constraints when modifying this repo

- Anything that needs elevated privilege must happen in the root phase of
  `entrypoint.sh`/`init-firewall.sh`, before `gosu` drops to `claude` — the
  `claude` user has no path back to root.
- Sessions default to `FIREWALL_MODE=open` (any host, ports 80/443 only). A
  session that needs tighter isolation should set `FIREWALL_MODE=strict` at
  launch time (plus `EXTRA_ALLOWED_DOMAINS` for any host beyond the built-in
  allowlist) rather than that becoming the new default for every session. A
  session that needs a non-web port (e.g. a DB) should use
  `EXTRA_ALLOWED_PORTS` at launch time rather than hardcoding into
  `init-firewall.sh`.
- Only `/workspace` and `/home/claude/.claude` persist across sessions. The
  rest of the container filesystem is ephemeral (discarded on `docker compose
  down`) — don't design changes that assume other paths survive a restart.
- `docker compose exec` does **not** run the image's `ENTRYPOINT`, so it
  bypasses `entrypoint.sh`'s `gosu` privilege drop and defaults to root.
  Any `exec` into a running session (`cc-container launch`'s attach path,
  or manual `docker compose exec`) must pass `--user claude` explicitly, or
  the process runs as root with capabilities stripped and cannot write to
  `/workspace` or `~/.claude` (owned by the `claude` user).
- `tr -c CHARSET REPL` translates *every* byte not in CHARSET, including
  a trailing newline carried through a pipe — e.g. `basename ... | tr -c
  'a-z0-9' '-'` turns `plrep\n` into `plrep-` with no newline left for
  `$(...)` to strip, silently appending a stray '-' to derived names.
  Strip/trim before or after any `tr -c` step in this style.
- `--env-file` (`SESSION_ENV_FILE` / `env_file:` in docker-compose.yml) only
  keeps secrets out of the *filesystem* Claude Code's Read/Grep/Glob tools
  can browse (`/workspace`). It does not hide them from the `claude` process
  itself — env vars set on a container are inherited by every `docker
  compose exec` session into it (including the one `cc-container launch`
  runs `claude` in), so a secret injected this way is still visible to
  anything Claude's Bash tool runs (e.g. `env`). Don't describe this flag as
  isolating secrets from the agent, only from casual file access/commits.
