#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_WORKSPACE="$(pwd)"
PROJECT_NAME="$(basename "$HOST_WORKSPACE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
IMAGE="codex-sandbox"
CONTAINER_HOME="${DEV_CONTAINER_HOME:-/home/node}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/${PROJECT_NAME}-codex-config.XXXXXX.toml")"
CODEX_CONTAINER_DIR="$CODEX_DIR"
NODE_MODULES_VOLUME="${DEV_CONTAINER_NODE_MODULES_VOLUME:-${PROJECT_NAME}-node-modules}"
CHROME_DEVTOOLS_PORT="${CHROME_DEVTOOLS_PORT:-9222}"
DEVTOOLS_PROXY_PORT="${DEVTOOLS_PROXY_PORT:-9223}"
SSH_ARGS=()
GITHUB_AUTH_ARGS=(
  -e GH_TOKEN
  -e GITHUB_TOKEN
  -e GIT_CONFIG_COUNT=1
  -e GIT_CONFIG_KEY_0=credential.https://github.com.helper
  -e 'GIT_CONFIG_VALUE_0=!f() { test "$1" = get || exit 0; token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"; test -n "$token" || exit 0; printf "username=x-access-token\npassword=%s\n" "$token"; }; f'
)
CONTAINER_CMD=("$@")

if [[ "$#" -eq 0 ]]; then
  CONTAINER_CMD=(codex --dangerously-bypass-approvals-and-sandbox -C "$HOST_WORKSPACE")
fi

cleanup() {
  if [[ -n "${DEVTOOLS_PROXY_PID:-}" ]]; then
    kill "$DEVTOOLS_PROXY_PID" >/dev/null 2>&1 || true
  fi
  rm -f -- "$CODEX_CONFIG_FILE"
}
trap cleanup EXIT

if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  SSH_ARGS=(
    -v "$SSH_AUTH_SOCK:/ssh-agent"
    -e SSH_AUTH_SOCK=/ssh-agent
  )
fi

IMAGE_CREATED_AT="$(docker image inspect --format '{{.Created}}' "$IMAGE" 2>/dev/null || true)"
if [[ -z "$IMAGE_CREATED_AT" ]]; then
  IMAGE_NEEDS_BUILD=1
else
  IMAGE_CREATED_EPOCH="$(date -d "$IMAGE_CREATED_AT" +%s)"
  DOCKERFILE_EPOCH="$(stat -c %Y "$SCRIPT_DIR/Dockerfile")"
  if [[ "$DOCKERFILE_EPOCH" -gt "$IMAGE_CREATED_EPOCH" ]]; then
    IMAGE_NEEDS_BUILD=1
  else
    IMAGE_NEEDS_BUILD=0
  fi
fi

if [[ "$IMAGE_NEEDS_BUILD" == 1 ]]; then
  docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

cp "$CODEX_DIR/config.toml" "$CODEX_CONFIG_FILE"

HOST_GATEWAY_IP="$(
  docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    "$IMAGE" \
    getent hosts host.docker.internal | awk '{print $1; exit}'
)"

sed -i -E "s#--browser-url=http://[^\" ]+#--browser-url=http://${HOST_GATEWAY_IP}:${DEVTOOLS_PROXY_PORT}#g" "$CODEX_CONFIG_FILE"
sed -i '/^\[mcp_servers\.chrome-devtools\]$/,/^\[/ s/^command = "npx"$/command = "chrome-devtools-mcp"/' "$CODEX_CONFIG_FILE"
sed -i -E '/^\[mcp_servers\.chrome-devtools\]$/,/^\[/ s#^args = \["-y", "chrome-devtools-mcp(@latest)?", ("--browser-url=[^"]+")\]#args = [\2]#' "$CODEX_CONFIG_FILE"
if ! grep -q '^\[mcp_servers\.chrome-devtools\.env\]$' "$CODEX_CONFIG_FILE"; then
  {
    echo
    echo "[mcp_servers.chrome-devtools.env]"
  } >> "$CODEX_CONFIG_FILE"
fi
sed -i '/^\[mcp_servers\.chrome-devtools\.env\]$/,/^\[/ {
  /^\[mcp_servers\.chrome-devtools\.env\]$/! {
    /^NPM_CONFIG_CACHE = /d
  }
}' "$CODEX_CONFIG_FILE"
sed -i '/^\[mcp_servers\.chrome-devtools\.env\]$/a NPM_CONFIG_CACHE = "/tmp/npm-cache"' "$CODEX_CONFIG_FILE"

# Register a devops-only subagent. Its system prompt is loaded from
# codex/agents/devops.md (mounted read-only below), and at runtime it is
# instructed to read project context exclusively from agent-devops.md at the
# workspace root.
DEVOPS_AGENT_CONTAINER_PATH="$CODEX_CONTAINER_DIR/agents/devops.md"
mkdir -p "$CODEX_DIR/agents"
cat >> "$CODEX_CONFIG_FILE" <<EOF

[[agents]]
name = "devops"
description = "Devops-only subagent. Use for CI/CD, deployments, infra, Docker/K8s, observability, secrets, release engineering."
instructions_file = "$DEVOPS_AGENT_CONTAINER_PATH"
model = "gpt-5.4-mini"
EOF

socat \
  "TCP-LISTEN:${DEVTOOLS_PROXY_PORT},fork,reuseaddr,bind=${HOST_GATEWAY_IP}" \
  "TCP:127.0.0.1:${CHROME_DEVTOOLS_PORT}" &
DEVTOOLS_PROXY_PID="$!"

DEVTOOLS_READY=0
for _ in {1..20}; do
  if curl -fsS "http://${HOST_GATEWAY_IP}:${DEVTOOLS_PROXY_PORT}/json/version" >/dev/null 2>&1; then
    DEVTOOLS_READY=1
    break
  fi
  sleep 0.1
done

if [[ "$DEVTOOLS_READY" != 1 ]]; then
  echo "Chrome DevTools was not reachable through ${HOST_GATEWAY_IP}:${DEVTOOLS_PROXY_PORT}." >&2
  echo "Make sure Chrome is running with --remote-debugging-port=${CHROME_DEVTOOLS_PORT}." >&2
  exit 1
fi

docker run --rm -it \
  --add-host=host.docker.internal:host-gateway \
  -v "$HOST_WORKSPACE:$HOST_WORKSPACE" \
  -w "$HOST_WORKSPACE" \
  -v "$CODEX_DIR:$CODEX_CONTAINER_DIR" \
  -v "$CODEX_CONFIG_FILE:$CODEX_CONTAINER_DIR/config.toml" \
  -v "$SCRIPT_DIR/agents/devops.md:$CODEX_CONTAINER_DIR/agents/devops.md:ro" \
  "${SSH_ARGS[@]}" \
  -e HOME="$CONTAINER_HOME" \
  -e CODEX_HOME="$CODEX_CONTAINER_DIR" \
  -e NPM_CONFIG_CACHE=/tmp/npm-cache \
  "${GITHUB_AUTH_ARGS[@]}" \
  -v "$NODE_MODULES_VOLUME:$HOST_WORKSPACE/node_modules" \
  --user "$(id -u):$(id -g)" \
  "$IMAGE" "${CONTAINER_CMD[@]}"
