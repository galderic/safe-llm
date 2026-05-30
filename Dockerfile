FROM golang:1.25-bookworm AS github-mcp-builder

ARG GITHUB_MCP_SERVER_VERSION=v1.0.5
RUN go install github.com/github/github-mcp-server/cmd/github-mcp-server@${GITHUB_MCP_SERVER_VERSION}

FROM node:22-bookworm AS base

LABEL org.opencontainers.image.title="safe-llm-sandbox"

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node
ENV CODEX_HOME=/home/node/.codex
ENV PATH="/usr/local/go/bin:$PATH"

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    dnsutils \
    gh \
    git \
    hcloud-cli \
    jq \
    libpcsclite-dev \
    lsof \
    netcat-openbsd \
    openssh-client \
    postgresql-client \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    shellcheck \
    socat \
    strace \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g chrome-devtools-mcp@latest \
  && python3 -m pip install --break-system-packages --no-cache-dir uv

COPY --from=github-mcp-builder /go/bin/github-mcp-server /usr/local/bin/github-mcp-server
COPY --from=github-mcp-builder /usr/local/go /usr/local/go

RUN printf '%s\n' \
    'case ":$PATH:" in' \
    '  *:/usr/local/go/bin:*) ;;' \
    '  *) export PATH="/usr/local/go/bin:$PATH" ;;' \
    'esac' \
    > /etc/profile.d/go-path.sh

RUN useradd -m -s /bin/bash claude \
  && mkdir -p /home/node/.codex /home/claude/.claude \
  && chown -R node:node /home/node \
  && chown -R claude:claude /home/claude

FROM base AS tools

RUN npm install -g @openai/codex

USER claude
ENV HOME=/home/claude
WORKDIR /home/claude/workspace
RUN curl -fsSL https://claude.ai/install.sh | bash

USER root
ENV PATH="/home/claude/.local/bin:$PATH"
ENV HOME=/home/node
WORKDIR /workspace
RUN test -x /home/claude/.local/bin/claude \
  && ln -sf /home/claude/.local/bin/claude /usr/local/bin/claude \
  && command -v claude \
  && command -v codex \
  && command -v go

FROM tools AS claude
CMD ["bash"]

FROM tools AS codex
CMD ["bash"]

FROM tools AS both
COPY scripts/safe-claude-review /usr/local/bin/safe-claude-review
COPY scripts/safe-codex-review /usr/local/bin/safe-codex-review
RUN chmod 0755 /usr/local/bin/safe-claude-review /usr/local/bin/safe-codex-review

CMD ["bash"]
