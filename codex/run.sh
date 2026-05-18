#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/sandbox.sh"

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
setup_github_auth_args
CONTAINER_CMD=("$@")

if [[ "$#" -eq 0 ]]; then
  CONTAINER_CMD=(codex --dangerously-bypass-approvals-and-sandbox -C "$HOST_WORKSPACE")
fi

# Path under $HOME/.codex where the devops subagent prompt is staged so the
# parent bind mount carries it into the container (see below for rationale).
STAGED_DEVOPS_AGENT_PATH=""

cleanup() {
  # Restore the user's original config.toml from the backup we made before
  # mutating it. If the backup is missing (script aborted before backup),
  # there's nothing to do.
  if [[ -f "$CODEX_CONFIG_BACKUP" ]]; then
    mv -f -- "$CODEX_CONFIG_BACKUP" "$CODEX_CONFIG_FILE"
  fi
  if [[ -n "$STAGED_DEVOPS_AGENT_PATH" && -f "$STAGED_DEVOPS_AGENT_PATH" ]]; then
    rm -f -- "$STAGED_DEVOPS_AGENT_PATH"
  fi
  sandbox_cleanup
}
trap cleanup EXIT

setup_ssh_args "$CONTAINER_HOME"
ensure_image_current "$IMAGE" "$SCRIPT_DIR"
setup_host_passwd_args "$IMAGE" "$CONTAINER_HOME" codex

# Back the user's config up, then mutate it in place. The Docker Desktop
# virtiofs driver refuses to nest-mount a tempfile inside the parent
# $HOME/.codex bind mount, so we have to edit the real file and restore it
# from the backup on exit (see cleanup()).
cp "$CODEX_CONFIG_FILE" "$CODEX_CONFIG_BACKUP"

setup_devtools "$IMAGE" "$CHROME_DEVTOOLS_PORT" "$DEVTOOLS_PROXY_PORT"

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

ensure_chrome_devtools

docker run --rm -it \
  --add-host=host.docker.internal:host-gateway \
  -v "$HOST_WORKSPACE:$HOST_WORKSPACE" \
  -w "$HOST_WORKSPACE" \
  -v "$CODEX_DIR:$CODEX_CONTAINER_DIR" \
  ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} \
  ${PASSWD_ARGS[@]+"${PASSWD_ARGS[@]}"} \
  -e HOME="$CONTAINER_HOME" \
  -e CODEX_HOME="$CODEX_CONTAINER_DIR" \
  -e NPM_CONFIG_CACHE=/tmp/npm-cache \
  "${GITHUB_AUTH_ARGS[@]}" \
  -v "$NODE_MODULES_VOLUME:$HOST_WORKSPACE/node_modules" \
  --user "$(id -u):$(id -g)" \
  "$IMAGE" "${CONTAINER_CMD[@]}"
