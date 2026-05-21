FROM node:22-slim

LABEL org.opencontainers.image.ref.name="claude-sandbox"

RUN apt-get update && apt-get install -y \
    git curl bash python3 python3-pip python3-venv strace socat shellcheck \
    gh hcloud-cli \
    && rm -rf /var/lib/apt/lists/*

# Install official Chrome DevTools MCP (as root, before switching user)
RUN npm install -g chrome-devtools-mcp@latest
RUN python3 -m pip install --break-system-packages --no-cache-dir uv

RUN usermod -l claude -d /home/claude -m node
USER claude
WORKDIR /home/claude/workspace

# Use the native installer instead of npm
RUN curl -fsSL https://claude.ai/install.sh | bash

ENV PATH="/home/claude/.local/bin:$PATH"
