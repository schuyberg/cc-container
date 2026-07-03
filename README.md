# Claude Code in Docker — hardened, multi-session setup

---

A containerized environment for running Claude Code. Project code is included in a mounted volume, and the container is hardened to improve security. This is not foolproof, but is somewhat more secure than running claude code directly on the host system.

The following documentation and project code is AI-Generated (Claude Sonnet 5).

----


Node + Claude Code, launched per-project on demand, with several layers of
containment: a non-root user, a mostly read-only filesystem, dropped Linux
capabilities, and an outbound network allowlist. Any number of sessions can
run concurrently, each mounting a different directory, sharing one login.

## What's containing what

| Risk | Mitigation |
|---|---|
| Writes outside the project | `read_only: true` root filesystem. Only `/workspace` (your project) and the auth volume are writable — there's structurally nowhere else on disk to write to. |
| Malicious code running with elevated privilege | Process runs as a non-root user with no `sudo`. `cap_drop: ALL` removes every Linux capability except the two (`NET_ADMIN`, `NET_RAW`) needed transiently by root at startup to configure the firewall — the actual `claude` process never has them. `no-new-privileges` blocks privilege escalation via setuid binaries. |
| Data exfiltration / pulling down more payloads | `init-firewall.sh` sets a default-deny outbound firewall, resolved at container start to only allow Anthropic's API, `claude.ai`, and common package/git registries (npm, PyPI, GitHub). Everything else outbound is dropped. |
| Fork bombs / resource exhaustion | `mem_limit` and `pids_limit` cap what one session can consume. |
| One project's session compromising another | Already true from the multi-session design — each project gets its own container, network, and ports; only the login is shared. |

None of this replaces Claude Code's own permission prompts — it's what
stands between you and trouble if you're running with looser permissions
(e.g. `--dangerously-skip-permissions`) or working with an untrusted repo.

**Limits, honestly**: the firewall is a DNS-resolved IP allowlist, not a
content-inspecting proxy — it stops arbitrary-host exfiltration but isn't
foolproof against DNS rebinding or a compromised allowed host. Container
isolation also isn't a hard security boundary against a determined kernel
exploit. Treat this as raising the bar substantially, not as an absolute
guarantee — don't run untrusted code with `--dangerously-skip-permissions`
expecting zero risk.

## First-time setup (once per machine)

```bash
chmod +x cc-container
./cc-container setup
```

This builds the image (with the container user's UID/GID matching your
host user, so files written into your project come out owned by you, not
some arbitrary container UID), creates the shared auth volume, and opens an
interactive login.

### Optional: alias it


```bash
# in ~/.bashrc or ~/.zshrc
alias cc='/path/to/cc-container-docker/cc-container'
```

Then every command below can be run as `cc launch ...`, `cc list`, etc.,
from anywhere.

## Launching sessions

```bash
./cc-container launch ~/projects/sooke-live
./cc-container launch ~/projects/dot-tally
```

Auto-named session, auto-picked free ports, already logged in, runs
concurrently with any other session. Running `launch` again on a directory
whose session is already up just attaches to it.

## Managing sessions

```bash
./cc-container list
./cc-container stop sooke-live
```

## Letting a project reach an extra host

If a project needs something outside the default allowlist (a private
package registry, an API you're integrating with), set it before launching:

```bash
EXTRA_ALLOWED_DOMAINS=my-registry.example.com ./cc-container launch ~/projects/foo
```

Comma-separate multiple domains. This only affects that session's
container.

## Connecting to a project's own services (e.g. a database)

Two ways to do this, depending on how the project is structured.

### Option A: embed the service in the project's own docker-compose.yml (recommended)

If a project already has its own `docker-compose.yml` (say, defining a
`db` service), the cleanest approach is to add a `cc-container` service to
*that* file, built from this repo's Dockerfile. Because Compose puts every
service defined in one file on a shared default network automatically, the
session can then reach the database simply as `db:5432` — no extra network
wiring needed.

See `examples/project-docker-compose.yml` for a full example. The short
version:

```yaml
services:
  db:
    image: postgres:16
    # ...

  cc-container:
    build:
      context: ../cc-container-docker   # path to this repo
      args:
        USER_UID: ${USER_UID:-1000}
        USER_GID: ${USER_GID:-1000}
    command: ["sleep", "infinity"]
    stdin_open: true
    tty: true
    cap_drop: [ALL]
    cap_add: [NET_ADMIN, NET_RAW]
    security_opt: [no-new-privileges:true]
    read_only: true
    tmpfs: ["/tmp:exec,size=1g", "/home/claude/.cache:size=512m"]
    volumes:
      - .:/workspace
      - claude-config:/home/claude/.claude   # reuse the shared login
    depends_on: [db]

volumes:
  claude-config:
    external: true
    name: claude-code-auth
```

Then, from that project's directory:

```bash
docker compose build
docker compose up -d
docker compose exec cc-container claude
```

It reuses the same shared `claude-code-auth` volume as the standalone
setup, so it's already logged in as long as you've run `cc-container setup`
at least once anywhere on the machine.

### Option B: attach a running session to an existing network

If you'd rather keep using `cc-container launch` as usual and just need
occasional access to a database (or other services) running in a separate
compose project, attach after the fact:

```bash
docker network ls                              # find the network's name
./cc-container launch ~/projects/sooke-live      # start the session as usual
./cc-container network sooke-live sooke-live_default
```

Docker Compose names a project's default network `<project-name>_default`
unless overridden. Once attached, the session can reach that project's
containers by their service name (e.g. `db:5432`).

This attachment doesn't persist across `stop`/`launch` cycles — re-run
`cc-container network` after restarting a session if you need it again.

## Notes

- **Shared auth, separate everything else.** All sessions log in as the
  same Claude account (one volume, `claude-code-auth`). Project files,
  ports, containers, and firewalls are isolated per session.
- **Non-interactive/CI use** still needs a token instead of the TTY login:
  run `claude setup-token` once and pass the result in as
  `CLAUDE_CODE_OAUTH_TOKEN`.
- Rebuilding the image (`docker compose build`) doesn't touch the auth
  volume, so Claude Code/Node upgrades don't force a re-login.
- If a session ever needs a genuinely unrestricted shell (e.g. debugging
  the firewall itself), you can temporarily comment out the `cap_drop`/
  `read_only` block in `docker-compose.yml` for that container — just
  remember to put it back.
