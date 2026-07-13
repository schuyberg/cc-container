# Claude Code in Docker — hardened, multi-session setup

---

A containerized environment for running Claude Code. Project code is included in a mounted volume, and the container is hardened to improve security. This is not foolproof, but is somewhat more secure than running claude code directly on the host system.

The following documentation and project code is AI-Generated (Claude Sonnet 5).

----


Node + Claude Code, launched per-project on demand, with several layers of
containment: a non-root user, an ephemeral filesystem, dropped Linux
capabilities, and an outbound firewall (open to any host on ports 80/443 by
default, or a strict domain allowlist on request). Any number of sessions
can run concurrently, each mounting a different directory, sharing one
login.

## What's containing what

| Risk | Mitigation |
|---|---|
| Writes outside the project | The container filesystem is writable but ephemeral — its overlay layer is discarded on `docker compose down`. Only `/workspace` (your project) and the auth volume actually persist across sessions. |
| Malicious code running with elevated privilege | Process runs as a non-root user with no `sudo`. `cap_drop: ALL` removes every Linux capability except the two (`NET_ADMIN`, `NET_RAW`) needed transiently by root at startup to configure the firewall — the actual `claude` process never has them. `no-new-privileges` blocks privilege escalation via setuid binaries. |
| Data exfiltration / pulling down more payloads | `init-firewall.sh` sets an outbound firewall. By default, any host is reachable but only on ports 80/443 (web browsing, search grounding, APIs) — every other port is dropped. `FIREWALL_MODE=strict` switches to a default-deny domain allowlist (Anthropic's API, `claude.ai`, common package/git registries) instead. |
| Fork bombs / resource exhaustion | `mem_limit` and `pids_limit` cap what one session can consume. |
| One project's session compromising another | Already true from the multi-session design — each project gets its own container, network, and ports; only the login is shared. |

None of this replaces Claude Code's own permission prompts — it's what
stands between you and trouble if you're running with looser permissions
(e.g. `--dangerously-skip-permissions`) or working with an untrusted repo.

**Limits, honestly**: in the default "open" mode, the firewall only
restricts by *port*, not destination — any host is reachable on 80/443, so
it doesn't stop exfiltration over HTTP(S) to an arbitrary server, only
non-web protocols (raw TCP, SSH, DB wire protocols, etc. to hosts you
haven't explicitly opened via `EXTRA_ALLOWED_PORTS`). If you need the
stronger guarantee — only named hosts reachable at all — use
`FIREWALL_MODE=strict`, which is a DNS-resolved IP allowlist, not a
content-inspecting proxy either (not foolproof against DNS rebinding or a
compromised allowed host). Container isolation also isn't a hard security
boundary against a determined kernel exploit. Treat either mode as raising
the bar substantially, not as an absolute guarantee — don't run untrusted
code with `--dangerously-skip-permissions` expecting zero risk.

### Claude can see anything in its own container

Claude Code's Bash tool runs as the `claude` user *inside* this same
container — it isn't a separate, more restricted process. That means:

- **Every environment variable** present in the container is visible to
  Claude, however it got there — `environment:` in a compose file,
  `--env-file`/`SESSION_ENV_FILE` (see below), or anything inherited from a
  parent process. Claude can read it with `env`, `printenv`, or anything
  else its Bash tool runs, not just with your own scripts.
- **Every file under a mounted path** (`/workspace`, or any extra bind
  mount) is readable by Claude's Read/Grep/Glob/Bash tools regardless of
  host file permissions, `.gitignore`, or whether it's tracked in git.

`launch --env-file <path>` (`SESSION_ENV_FILE` in `docker-compose.yml`)
loads `KEY=VALUE` pairs from a host file straight into the container's
environment, without ever bind-mounting that file into `/workspace`:

```bash
./cc-container launch ~/projects/foo --env-file ~/secrets/foo.env
```

This is worth doing — it keeps a secret off disk under `/workspace`, out of
git, and away from casual file browsing. But it does **not** hide the
secret from Claude itself: once it's an env var in this container, Claude's
Bash tool can read it just as easily as your own shell could. If a secret
needs to stay genuinely invisible to Claude — not just off disk — it can't
be injected into this container at all; see [Keeping secrets private from
Claude](#keeping-secrets-private-from-claude) below for a pattern that
achieves that.

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
./cc-container shell sooke-live
./cc-container stop sooke-live
```

`shell` attaches to a running session with a bash shell instead of
launching `claude` — handy for poking around, running one-off commands, or
debugging the container itself. Like `launch`'s attach path, it runs as
the `claude` user, not root.

## Locking a session down further

By default every session can reach any host on ports 80/443. If a
particular session should be restricted to a named set of hosts instead
(e.g. working with an untrusted repo), switch it to strict mode at launch:

```bash
FIREWALL_MODE=strict ./cc-container launch ~/projects/foo
```

Strict mode allows only Anthropic's API, `claude.ai`, and common
package/git registries (npm, PyPI, GitHub) by default. Add more hosts to
that session with `EXTRA_ALLOWED_DOMAINS`:

```bash
FIREWALL_MODE=strict EXTRA_ALLOWED_DOMAINS=my-registry.example.com ./cc-container launch ~/projects/foo
```

Comma-separate multiple domains. This only affects that session's
container, and `FIREWALL_MODE`/`EXTRA_ALLOWED_DOMAINS` are fixed at
container creation — changing them requires `stop` + relaunch.

## Opening a non-web port

Both modes only allow outbound 80/443 by default. If a session needs to
reach something else directly (a database, SSH), open the specific port(s)
for any destination at launch:

```bash
EXTRA_ALLOWED_PORTS=5432,22 ./cc-container launch ~/projects/foo
```

For a project's *own* backing services, prefer the Compose-network
approaches below instead — they don't require opening a port to the whole
internet.

## Connecting to a project's own services (e.g. a database)

Two ways to do this, depending on how the project is structured.

### Option A: embed the service in the project's own docker-compose.yml (recommended)

If a project already has its own `docker-compose.yml` (say, defining a
`db` service), the cleanest approach is to add a `cc-container` service to
*that* file, built from this repo's Dockerfile. Because Compose puts every
service defined in one file on a shared default network automatically, the
session can then reach the database simply as `db:5432` — no extra network
wiring needed.

See `project-docker-compose.yml` (in this repo) for a full example. The
short version:

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
    working_dir: /workspace/myproject   # distinct cwd, see project-docker-compose.yml
    cap_drop: [ALL]
    cap_add: [NET_ADMIN, NET_RAW]
    security_opt: [no-new-privileges:true]
    read_only: true
    tmpfs: ["/tmp:exec,size=1g", "/home/claude/.cache:size=512m"]
    volumes:
      - .:/workspace/myproject
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
docker compose exec --user claude cc-container claude
```

It reuses the same shared `claude-code-auth` volume as the standalone
setup, so it's already logged in as long as you've run `cc-container setup`
at least once anywhere on the machine.

**Reconnecting later:** `docker compose up -d` is idempotent — it starts
the container if it's stopped and no-ops instantly if it's already
running — so the same two commands work whether this is the first
connection or a reconnect:

```bash
docker compose up -d
docker compose exec --user claude cc-container claude --continue
```

(Omit `--continue` on the very first run, since there's no conversation
yet to continue.) A shell function saves you from remembering the pair,
e.g. in `.bashrc`/`.zshrc`:

```bash
ccdev() { docker compose up -d && docker compose exec --user claude cc-container claude --continue "$@"; }
```

Then `ccdev` from the project directory connects or reconnects either way.
Use `docker compose ps` to check whether the session is currently running,
and `docker compose down` to stop and remove it.

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

## Keeping secrets private from Claude

As covered [above](#claude-can-see-anything-in-its-own-container), any
secret that lands in this container's environment or filesystem is visible
to Claude — `--env-file` only keeps it off disk and out of git, not out of
Claude's reach. The only way to keep a secret genuinely invisible to Claude
is to never give this container the secret at all, and instead put it only
on the service that actually needs it.

**The line that matters:** does Claude itself need to *use* the credential
(run `psql` with it, call a paid API directly from a script it writes), or
does some other service use it *on Claude's behalf* (a backend process
that Claude only talks to over HTTP)? Only the second case can be made
fully private — if Claude has to present the credential itself to make
something work, it will see that credential, and no container boundary
changes that.

For the "on Claude's behalf" case, extend the [multi-container
pattern](#option-a-embed-the-service-in-the-projects-own-docker-composeyml-recommended)
from above: put the secret only in `environment:`/`env_file:` on the
service that needs it, give `cc-container` no such variable, and have
Claude reach that service by its Compose service name instead of a raw
credential. For example, a `backend` service that calls a paid third-party
API:

```yaml
services:
  backend:
    build: ./backend
    env_file:
      - ./backend/.env.secret   # holds THIRD_PARTY_API_KEY; never committed
    # no ports: needed unless the host also needs direct access

  cc-container:
    build:
      context: ../cc-container-docker
      args:
        USER_UID: ${USER_UID:-1000}
        USER_GID: ${USER_GID:-1000}
    # ...same as project-docker-compose.yml...
    # deliberately NOT given THIRD_PARTY_API_KEY, or any env_file containing it
    depends_on: [backend]
```

Claude can now run `curl http://backend:8000/some-endpoint` to exercise
functionality that depends on the key, and can read `backend`'s source
code to understand what it does with it, but the key's *value* never
appears anywhere in `cc-container`'s environment or mounted files —
`env`, `printenv`, and `/workspace` all come up empty for it. Docker
containers don't share process namespaces or each other's environments by
default, and `cc-container` has no `docker exec`/`docker inspect` access
into `backend` (no Docker socket is mounted), so there's no route from one
container to the other's environment short of `backend` handing the value
back over the network itself.

For the unavoidable case — Claude genuinely needs a working credential
(e.g. a database password to run migrations) — you can't hide the value,
but you can shrink the blast radius:

- Use a **dev-only credential**, scoped to a disposable resource (a local
  `db` container, a sandbox/test API key), never the same one used in
  staging or production.
- Pair it with `FIREWALL_MODE=strict` (see [Locking a session down
  further](#locking-a-session-down-further)) so that even if Claude tried
  to exfiltrate the value, only an explicit allowlist of hosts is
  reachable at all.
- Prefer a role/key with the minimum privilege the task actually needs
  (e.g. a Postgres role that can only touch a scratch database) over
  reusing an admin credential.

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
  the firewall itself), you can temporarily comment out the `cap_drop`
  block in `docker-compose.yml` for that container — just remember to put
  it back.
