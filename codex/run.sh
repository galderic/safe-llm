#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/sandbox.sh"
DEVOPS_AGENT_FILE="$REPO_ROOT/agents/devops.md"
PLANE_MCP_WRAPPER_FILE="$REPO_ROOT/scripts/plane-mcp-stdio-wrapper.py"

if [[ "${1:-}" == "--rebuild" ]]; then
  SAFE_LLM_REBUILD=1
  shift
fi

HOST_WORKSPACE="$(pwd)"
PROJECT_NAME="$(basename "$HOST_WORKSPACE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
IMAGE="codex-sandbox"
CONTAINER_HOME="${DEV_CONTAINER_HOME:-/home/node}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONTAINER_DIR="$CODEX_DIR"
NODE_MODULES_VOLUME="${DEV_CONTAINER_NODE_MODULES_VOLUME:-${PROJECT_NAME}-node-modules}"
UV_CACHE_DIR_CONTAINER="${UV_CACHE_DIR_CONTAINER:-/tmp/uv-cache}"
UV_TOOL_DIR_CONTAINER="${UV_TOOL_DIR_CONTAINER:-/tmp/uv-tools}"
PLANE_MCP_WRAPPER_CONTAINER="${PLANE_MCP_WRAPPER_CONTAINER:-/tmp/plane-mcp-stdio-wrapper.py}"
CHROME_DEVTOOLS_PORT="${CHROME_DEVTOOLS_PORT:-9222}"
DEVTOOLS_PROXY_PORT="${DEVTOOLS_PROXY_PORT:-9223}"
CODEX_SANDBOX_DEVELOPER_INSTRUCTIONS="${CODEX_SANDBOX_DEVELOPER_INSTRUCTIONS:-When browser automation is needed, prefer the chrome-devtools MCP server directly when its tools are available. Do not route browser work through the Browser plugin or browser skill unless a higher-priority instruction explicitly requires it.}"
SSH_ARGS=()
setup_github_auth_args

# Path under $HOME/.codex where the devops subagent prompt is staged so the
# parent bind mount carries it into the container (see below for rationale).
STAGED_DEVOPS_AGENT_PATH=""

cleanup() {
  if [[ -n "$STAGED_DEVOPS_AGENT_PATH" && -f "$STAGED_DEVOPS_AGENT_PATH" ]]; then
    rm -f -- "$STAGED_DEVOPS_AGENT_PATH"
  fi
  sandbox_cleanup
}
trap cleanup EXIT

setup_ssh_args "$CONTAINER_HOME"
setup_terminal_args
ensure_image_current "$IMAGE" "$SCRIPT_DIR"
setup_host_passwd_args "$IMAGE" "$CONTAINER_HOME" codex

setup_devtools "$IMAGE" "$CHROME_DEVTOOLS_PORT" "$DEVTOOLS_PROXY_PORT"

CODEX_CONFIG_OVERRIDES=(
  -c "developer_instructions=\"$CODEX_SANDBOX_DEVELOPER_INSTRUCTIONS\""
  -c 'mcp_servers.chrome-devtools.enabled=true'
  -c 'mcp_servers.chrome-devtools.required=false'
  -c 'mcp_servers.chrome-devtools.command="chrome-devtools-mcp"'
  -c "mcp_servers.chrome-devtools.args=[\"--browser-url=${DEVTOOLS_BROWSER_URL}\"]"
  -c 'mcp_servers.chrome-devtools.env={ NPM_CONFIG_CACHE = "/tmp/npm-cache" }'
)

if [[ -n "${PLANE_API_KEY:-}" && -n "${PLANE_WORKSPACE_SLUG:-}" ]]; then
  CODEX_CONFIG_OVERRIDES+=(
    -c 'mcp_servers.plane.enabled=true'
    -c 'mcp_servers.plane.required=false'
    -c 'mcp_servers.plane.command="uvx"'
    -c "mcp_servers.plane.args=[\"--from\", \"plane-mcp-server\", \"python\", \"${PLANE_MCP_WRAPPER_CONTAINER}\", \"stdio\"]"
    -c 'mcp_servers.plane.env={}'
    -c 'mcp_servers.plane.env_vars=["UV_CACHE_DIR", "UV_TOOL_DIR", "PLANE_MCP_TOOL_GROUPS", "PLANE_BASE_URL", "PLANE_API_KEY", "PLANE_WORKSPACE_SLUG"]'
    -c 'mcp_servers.plane.startup_timeout_sec=30'
  )
else
  CODEX_CONFIG_OVERRIDES+=(
    -c 'mcp_servers.plane.enabled=false'
    -c 'mcp_servers.plane.command="uvx"'
    -c "mcp_servers.plane.args=[\"--from\", \"plane-mcp-server\", \"python\", \"${PLANE_MCP_WRAPPER_CONTAINER}\", \"stdio\"]"
    -c 'mcp_servers.plane.env={}'
    -c 'mcp_servers.plane.env_vars=[]'
  )
fi

# Register a devops-only subagent as a standalone custom-agent TOML file.
# The parent $CODEX_DIR bind mount carries it into the container, and cleanup
# removes it from the host after the session.
mkdir -p "$CODEX_DIR/agents"
STAGED_DEVOPS_AGENT_PATH="$CODEX_DIR/agents/devops.toml"
python3 - "$DEVOPS_AGENT_FILE" "$STAGED_DEVOPS_AGENT_PATH" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
instructions = source.read_text()
if instructions.startswith("---\n"):
    _, separator, body = instructions.partition("\n---\n")
    if separator:
        instructions = body.lstrip()
target.write_text(
    'name = "devops"\n'
    'description = "Devops-only subagent. Use for CI/CD, deployments, infra, Docker/K8s, observability, secrets, release engineering."\n'
    'model = "gpt-5.4-mini"\n'
    f'developer_instructions = {json.dumps(instructions)}\n'
)
PY

if [[ "$#" -eq 0 ]]; then
  CONTAINER_CMD=(
    codex
    "${CODEX_CONFIG_OVERRIDES[@]}"
    --dangerously-bypass-approvals-and-sandbox
    -C "$HOST_WORKSPACE"
  )
elif [[ "${1:-}" == "codex" ]]; then
  CONTAINER_CMD=(codex "${CODEX_CONFIG_OVERRIDES[@]}" "${@:2}")
else
  CONTAINER_CMD=("$@")
fi

ensure_chrome_devtools

docker run --rm -it \
  --add-host=host.docker.internal:host-gateway \
  -v "$HOST_WORKSPACE:$HOST_WORKSPACE" \
  -w "$HOST_WORKSPACE" \
  -v "$CODEX_DIR:$CODEX_CONTAINER_DIR" \
  -v "$PLANE_MCP_WRAPPER_FILE:$PLANE_MCP_WRAPPER_CONTAINER:ro" \
  ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} \
  ${PASSWD_ARGS[@]+"${PASSWD_ARGS[@]}"} \
  "${TERMINAL_ARGS[@]}" \
  -e HOME="$CONTAINER_HOME" \
  -e CODEX_HOME="$CODEX_CONTAINER_DIR" \
  -e NPM_CONFIG_CACHE=/tmp/npm-cache \
  -e UV_CACHE_DIR="$UV_CACHE_DIR_CONTAINER" \
  -e UV_TOOL_DIR="$UV_TOOL_DIR_CONTAINER" \
  -e PLANE_MCP_TOOL_GROUPS="${PLANE_MCP_TOOL_GROUPS:-work_items,work_item_comments,states}" \
  -e HCLOUD_TOKEN="${HCLOUD_TOKEN:-}" \
  -e PLANE_BASE_URL="${PLANE_BASE_URL:-}" \
  -e PLANE_API_KEY="${PLANE_API_KEY:-}" \
  -e PLANE_WORKSPACE_SLUG="${PLANE_WORKSPACE_SLUG:-}" \
  "${GITHUB_AUTH_ARGS[@]}" \
  -v "$NODE_MODULES_VOLUME:$HOST_WORKSPACE/node_modules" \
  --user "$(id -u):$(id -g)" \
  "$IMAGE" "${CONTAINER_CMD[@]}"
