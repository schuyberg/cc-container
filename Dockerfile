# Claude Code development container — hardened variant
FROM node:22-slim

ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# iptables/getent for the outbound firewall, gosu to drop root cleanly.
# chromium: headless browser for debugging browser-driven apps (drive it
# with Playwright's Node driver, installed below, pointed at
# /usr/bin/chromium via executablePath — cap_drop: ALL in compose means
# Chromium's own sandbox can't be used, so launch with --no-sandbox).
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    less \
    vim \
    iptables \
    gosu \
    python3 \
    python3-pip \
    python3-venv \
    chromium \
    && rm -rf /var/lib/apt/lists/*

# Non-root user. UID/GID default to 1000 but should be built to match your
# host user (setup.sh does this) so files written into the bind-mounted
# project directory come out owned by you, not some arbitrary container UID.
RUN \
    existing_group="$(getent group "$USER_GID" | cut -d: -f1 || true)" \
    && if [ -n "$existing_group" ] && [ "$existing_group" != "$USERNAME" ]; then \
         groupmod -n "$USERNAME" "$existing_group"; \
       elif [ -z "$existing_group" ]; then \
         groupadd --gid "$USER_GID" "$USERNAME"; \
       fi \
    && existing_user="$(getent passwd "$USER_UID" | cut -d: -f1 || true)" \
    && if [ -n "$existing_user" ] && [ "$existing_user" != "$USERNAME" ]; then \
         usermod -l "$USERNAME" -d "/home/$USERNAME" -s /bin/bash -m "$existing_user"; \
       elif [ -z "$existing_user" ]; then \
         useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /bin/bash "$USERNAME"; \
       fi

# Install from /tmp, not /. Installing as root from / makes the installer
# scan the entire filesystem, which can hang or eat memory.
WORKDIR /tmp
RUN npm install -g @anthropic-ai/claude-code opencode-ai

# Playwright's Node driver for the apt-installed Chromium above. Skip
# Playwright's own browser download (PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1) -
# we already have a browser binary at /usr/bin/chromium and don't need a
# second copy; pass executablePath to chromium.launch() to use it.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm install -g playwright

# npm install -g runs as root, so the global install tree comes out
# root-owned (0755) with no group/other write bit. Since the claude user has
# no path back to root, self-update (claude's own `npm install -g` re-run)
# would fail with EACCES on a writable filesystem too unless this is handed
# over to the claude user now.
RUN chown -R "$USERNAME:$USERNAME" /usr/local/lib/node_modules /usr/local/bin

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace
RUN chown "$USERNAME:$USERNAME" /workspace

# Pre-create the auth/config dirs owned by the claude user. Docker copies a
# named volume's mount point from the image on first use (when the volume is
# empty), so this ensures fresh volumes start with the right ownership instead
# of root:root. Covers both agents: Claude Code keys everything (auth +
# settings) off ~/.claude; opencode splits it into an XDG data dir (auth.json)
# and XDG config dir (opencode.json, themes, etc).
RUN mkdir -p /home/"$USERNAME"/.claude \
             /home/"$USERNAME"/.local/share/opencode \
             /home/"$USERNAME"/.config/opencode \
    && chown -R "$USERNAME:$USERNAME" /home/"$USERNAME"/.claude \
                                       /home/"$USERNAME"/.local \
                                       /home/"$USERNAME"/.config

# Container starts as root (needed to set up the firewall via NET_ADMIN),
# then entrypoint.sh drops to the non-root user for everything else.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
