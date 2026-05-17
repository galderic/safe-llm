#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_WORKSPACE="$(pwd)"
PROJECT_NAME="$(basename "$HOST_WORKSPACE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
IMAGE="codex-sandbox"
CONTAINER_HOME="${DEV_CONTAINER_HOME:-/home/node}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONFIG_FILE="$CODEX_DIR/config.toml"
CODEX_CONFIG_BACKUP="$CODEX_DIR/config.toml.safellm-bak-$$"
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

# Path under $HOME/.codex where the devops subagent prompt is staged so the
# parent bind mount carries it into the container (see below for rationale).
STAGED_DEVOPS_AGENT_PATH=""

cleanup() {
  if [[ -n "${DEVTOOLS_PROXY_PID:-}" ]]; then
    kill "$DEVTOOLS_PROXY_PID" >/dev/null 2>&1 || true
  fi
  # Restore the user's original config.toml from the backup we made before
  # mutating it. If the backup is missing (script aborted before backup),
  # there's nothing to do.
  if [[ -f "$CODEX_CONFIG_BACKUP" ]]; then
    mv -f -- "$CODEX_CONFIG_BACKUP" "$CODEX_CONFIG_FILE"
  fi
  if [[ -n "$STAGED_DEVOPS_AGENT_PATH" && -f "$STAGED_DEVOPS_AGENT_PATH" ]]; then
    rm -f -- "$STAGED_DEVOPS_AGENT_PATH"
  fi
}
trap cleanup EXIT

HOST_OS="$(uname -s)"

# Portable mtime / ISO-8601-to-epoch helpers (GNU coreutils on Linux, BSD
# on macOS).
file_mtime() {
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

iso_to_epoch() {
  if date -d "$1" +%s >/dev/null 2>&1; then
    date -d "$1" +%s
  else
    local ts="${1%%.*}"
    ts="${ts%Z}"
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s
  fi
}

# Portable in-place sed. BSD sed (macOS) requires an explicit suffix
# argument after -i; passing '' means no backup file.
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# Forward the host's ssh-agent into the container.
#
# Linux: bind-mount the agent socket pointed to by $SSH_AUTH_SOCK directly.
#
# macOS (Docker Desktop): the host's launchd agent socket lives outside the
# VM and isn't reachable from a bind mount. Docker Desktop instead exposes
# the host agent at the magic path /run/host-services/ssh-auth.sock — that
# path doesn't exist on the host filesystem; Docker Desktop intercepts the
# -v source and synthesizes the socket inside the container. Requires keys
# loaded on the host (`ssh-add -l`).
if [[ "$HOST_OS" == "Darwin" ]]; then
  SSH_ARGS=(
    -v /run/host-services/ssh-auth.sock:/ssh-agent
    -e SSH_AUTH_SOCK=/ssh-agent
  )
elif [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
  SSH_ARGS=(
    -v "$SSH_AUTH_SOCK:/ssh-agent"
    -e SSH_AUTH_SOCK=/ssh-agent
  )
fi

IMAGE_CREATED_AT="$(docker image inspect --format '{{.Created}}' "$IMAGE" 2>/dev/null || true)"
if [[ -z "$IMAGE_CREATED_AT" ]]; then
  IMAGE_NEEDS_BUILD=1
else
  IMAGE_CREATED_EPOCH="$(iso_to_epoch "$IMAGE_CREATED_AT")"
  DOCKERFILE_EPOCH="$(file_mtime "$SCRIPT_DIR/Dockerfile")"
  if [[ "$DOCKERFILE_EPOCH" -gt "$IMAGE_CREATED_EPOCH" ]]; then
    IMAGE_NEEDS_BUILD=1
  else
    IMAGE_NEEDS_BUILD=0
  fi
fi

if [[ "$IMAGE_NEEDS_BUILD" == 1 ]]; then
  docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

# Back the user's config up, then mutate it in place. The Docker Desktop
# virtiofs driver refuses to nest-mount a tempfile inside the parent
# $HOME/.codex bind mount, so we have to edit the real file and restore it
# from the backup on exit (see cleanup()).
cp "$CODEX_CONFIG_FILE" "$CODEX_CONFIG_BACKUP"

# Pick how the container reaches the host's Chrome DevTools endpoint.
# See claude/run.sh for the full rationale: on Linux we run a socat proxy
# bound to the bridge gateway IP; on macOS Docker Desktop's built-in
# host.docker.internal NATs into the host loopback, so we skip the proxy.
if [[ "$HOST_OS" == "Linux" ]]; then
  HOST_GATEWAY_IP="$(
    docker run --rm \
      --add-host=host.docker.internal:host-gateway \
      "$IMAGE" \
      getent ahostsv4 host.docker.internal | awk '{print $1; exit}'
  )"
  DEVTOOLS_HOST_FOR_CONTAINER="$HOST_GATEWAY_IP"
  DEVTOOLS_PORT_FOR_CONTAINER="$DEVTOOLS_PROXY_PORT"
  HOST_PROBE_URL="http://${HOST_GATEWAY_IP}:${DEVTOOLS_PROXY_PORT}/json/version"
else
  DEVTOOLS_HOST_FOR_CONTAINER="host.docker.internal"
  DEVTOOLS_PORT_FOR_CONTAINER="$CHROME_DEVTOOLS_PORT"
  HOST_PROBE_URL="http://127.0.0.1:${CHROME_DEVTOOLS_PORT}/json/version"
fi
DEVTOOLS_BROWSER_URL="http://${DEVTOOLS_HOST_FOR_CONTAINER}:${DEVTOOLS_PORT_FOR_CONTAINER}"

# Rewrite the chrome-devtools MCP entry only if the user already has one
# in their config.toml. The transformations assume an existing block
# (typically authored via `codex mcp add`); appending only the .env table
# without a parent server definition produces a half-entry that Codex
# rejects at startup.
if grep -q '^\[mcp_servers\.chrome-devtools\]$' "$CODEX_CONFIG_FILE"; then
  sed_inplace -E "s#--browser-url=http://[^\" ]+#--browser-url=${DEVTOOLS_BROWSER_URL}#g" "$CODEX_CONFIG_FILE"
  sed_inplace '/^\[mcp_servers\.chrome-devtools\]$/,/^\[/ s/^command = "npx"$/command = "chrome-devtools-mcp"/' "$CODEX_CONFIG_FILE"
  sed_inplace -E '/^\[mcp_servers\.chrome-devtools\]$/,/^\[/ s#^args = \["-y", "chrome-devtools-mcp(@latest)?", ("--browser-url=[^"]+")\]#args = [\2]#' "$CODEX_CONFIG_FILE"
  if ! grep -q '^\[mcp_servers\.chrome-devtools\.env\]$' "$CODEX_CONFIG_FILE"; then
    {
      echo
      echo "[mcp_servers.chrome-devtools.env]"
    } >> "$CODEX_CONFIG_FILE"
  fi
  sed_inplace '/^\[mcp_servers\.chrome-devtools\.env\]$/,/^\[/ {
    /^\[mcp_servers\.chrome-devtools\.env\]$/! {
      /^NPM_CONFIG_CACHE = /d
    }
  }' "$CODEX_CONFIG_FILE"
  sed_inplace '/^\[mcp_servers\.chrome-devtools\.env\]$/a\
NPM_CONFIG_CACHE = "/tmp/npm-cache"
' "$CODEX_CONFIG_FILE"
fi

# Register a devops-only subagent. Its system prompt lives in
# codex/agents/devops.md (alongside this script). We can't nest-mount that
# file inside the container's $CODEX_DIR — Docker Desktop's virtiofs
# refuses to create a mountpoint inside an already-virtiofs-mounted
# directory — so stage it as a real file in $HOME/.codex/agents/ and let
# the parent bind mount carry it in. Cleaned up on exit so the host's
# ~/.codex is left untouched.
DEVOPS_AGENT_CONTAINER_PATH="$CODEX_CONTAINER_DIR/agents/devops.md"
mkdir -p "$CODEX_DIR/agents"
STAGED_DEVOPS_AGENT_PATH="$CODEX_DIR/agents/devops.md"
cp "$SCRIPT_DIR/agents/devops.md" "$STAGED_DEVOPS_AGENT_PATH"
cat >> "$CODEX_CONFIG_FILE" <<EOF

[agents.devops]
description = "Devops-only subagent. Use for CI/CD, deployments, infra, Docker/K8s, observability, secrets, release engineering."
instructions_file = "$DEVOPS_AGENT_CONTAINER_PATH"
model = "gpt-5.4-mini"
EOF

if [[ "$HOST_OS" == "Linux" ]]; then
  socat \
    "TCP-LISTEN:${DEVTOOLS_PROXY_PORT},fork,reuseaddr,bind=${HOST_GATEWAY_IP}" \
    "TCP:127.0.0.1:${CHROME_DEVTOOLS_PORT}" &
  DEVTOOLS_PROXY_PID="$!"
fi

probe_devtools() {
  local i
  for i in {1..20}; do
    if curl -fsS "$HOST_PROBE_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Launch Chrome with remote debugging on $CHROME_DEVTOOLS_PORT. A dedicated
# --user-data-dir is required because Chrome forwards command-line flags to
# any already-running instance and silently ignores --remote-debugging-port
# when it does — a separate profile dir forces a fresh process that actually
# opens the debug port.
start_chrome() {
  local profile_dir="${CHROME_DEBUG_PROFILE_DIR:-${TMPDIR:-/tmp}/chrome-devtools-profile-${CHROME_DEVTOOLS_PORT}}"
  mkdir -p "$profile_dir"
  if [[ "$HOST_OS" == "Darwin" ]]; then
    local chrome_bin="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if [[ ! -x "$chrome_bin" ]]; then
      echo "Could not find Google Chrome at: $chrome_bin" >&2
      return 1
    fi
    "$chrome_bin" \
      --remote-debugging-port="$CHROME_DEVTOOLS_PORT" \
      --user-data-dir="$profile_dir" \
      >/dev/null 2>&1 &
    disown || true
  else
    local chrome_bin
    for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
      if command -v "$candidate" >/dev/null 2>&1; then
        chrome_bin="$candidate"
        break
      fi
    done
    if [[ -z "${chrome_bin:-}" ]]; then
      echo "Could not find a Chrome/Chromium binary on PATH." >&2
      return 1
    fi
    "$chrome_bin" \
      --remote-debugging-port="$CHROME_DEVTOOLS_PORT" \
      --user-data-dir="$profile_dir" \
      >/dev/null 2>&1 &
    disown || true
  fi
}

if ! probe_devtools; then
  echo "Chrome DevTools not reachable at ${HOST_PROBE_URL}; starting Chrome..." >&2
  if ! start_chrome; then
    exit 1
  fi
  DEVTOOLS_READY=0
  for _ in {1..100}; do
    if curl -fsS "$HOST_PROBE_URL" >/dev/null 2>&1; then
      DEVTOOLS_READY=1
      break
    fi
    sleep 0.2
  done
  if [[ "$DEVTOOLS_READY" != 1 ]]; then
    echo "Chrome DevTools still not reachable at ${HOST_PROBE_URL} after launching Chrome." >&2
    exit 1
  fi
fi

docker run --rm -it \
  --add-host=host.docker.internal:host-gateway \
  -v "$HOST_WORKSPACE:$HOST_WORKSPACE" \
  -w "$HOST_WORKSPACE" \
  -v "$CODEX_DIR:$CODEX_CONTAINER_DIR" \
  ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} \
  -e HOME="$CONTAINER_HOME" \
  -e CODEX_HOME="$CODEX_CONTAINER_DIR" \
  -e NPM_CONFIG_CACHE=/tmp/npm-cache \
  "${GITHUB_AUTH_ARGS[@]}" \
  -v "$NODE_MODULES_VOLUME:$HOST_WORKSPACE/node_modules" \
  --user "$(id -u):$(id -g)" \
  "$IMAGE" "${CONTAINER_CMD[@]}"
