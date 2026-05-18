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
    jq \
    openssh-client \
    ripgrep \
    shellcheck \
    socat \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex chrome-devtools-mcp@latest

RUN mkdir -p /home/node/.codex \
  && chown -R node:node /home/node/.codex

WORKDIR /workspace

CMD ["bash"]
