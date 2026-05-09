#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="$(basename "$WORKSPACE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
IMAGE="codex-sandbox"
CONTAINER_HOME="${DEV_CONTAINER_HOME:-/home/node}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/${PROJECT_NAME}-codex-config.XXXXXX.toml")"
CODEX_CONTAINER_DIR="$CONTAINER_HOME/.codex"
NODE_MODULES_VOLUME="${DEV_CONTAINER_NODE_MODULES_VOLUME:-${PROJECT_NAME}-node-modules}"
CHROME_DEVTOOLS_PORT="${CHROME_DEVTOOLS_PORT:-9222}"
DEVTOOLS_PROXY_PORT="${DEVTOOLS_PROXY_PORT:-9223}"
SSH_ARGS=()
CONTAINER_CMD=("$@")

if [[ "$#" -eq 0 ]]; then
  CONTAINER_CMD=(codex --dangerously-bypass-approvals-and-sandbox -C /workspace)
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

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -t "$IMAGE" "$WORKSPACE"
fi

cp "$CODEX_DIR/config.toml" "$CODEX_CONFIG_FILE"

HOST_GATEWAY_IP="$(
  docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    "$IMAGE" \
    getent hosts host.docker.internal | awk '{print $1; exit}'
)"

sed -i -E "s#--browser-url=http://[^\" ]+#--browser-url=http://${HOST_GATEWAY_IP}:${DEVTOOLS_PROXY_PORT}#g" "$CODEX_CONFIG_FILE"
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
  -v "$WORKSPACE:/workspace" \
  -w /workspace \
  -v "$CODEX_DIR:$CODEX_CONTAINER_DIR" \
  -v "$CODEX_CONFIG_FILE:$CODEX_CONTAINER_DIR/config.toml" \
  "${SSH_ARGS[@]}" \
  -e HOME="$CONTAINER_HOME" \
  -e CODEX_HOME="$CODEX_CONTAINER_DIR" \
  -e NPM_CONFIG_CACHE=/tmp/npm-cache \
  -v "$NODE_MODULES_VOLUME:/workspace/node_modules" \
  --user "$(id -u):$(id -g)" \
  "$IMAGE" "${CONTAINER_CMD[@]}"
