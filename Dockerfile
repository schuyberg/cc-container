# Claude Code development container — hardened variant
FROM node:20-slim

ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# iptables/getent for the outbound firewall, gosu to drop root cleanly
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    less \
    vim \
    iptables \
    gosu \
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
RUN npm install -g @anthropic-ai/claude-code

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace
RUN chown "$USERNAME:$USERNAME" /workspace

# Container starts as root (needed to set up the firewall via NET_ADMIN),
# then entrypoint.sh drops to the non-root user for everything else.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
