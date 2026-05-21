FROM node:22-bookworm

LABEL org.opencontainers.image.title="codex-sandbox"

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node
ENV CODEX_HOME=/home/node/.codex

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    hcloud-cli \
    jq \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    shellcheck \
    socat \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex chrome-devtools-mcp@latest
RUN python3 -m pip install --break-system-packages --no-cache-dir uv

RUN mkdir -p /home/node/.codex \
  && chown -R node:node /home/node/.codex

WORKDIR /workspace

CMD ["bash"]
