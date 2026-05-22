#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/lib/sandbox.sh"
DEVOPS_AGENT_FILE="$REPO_ROOT/agents/devops.md"
MANAGER_AGENT_FILE="$REPO_ROOT/agents/manager.md"
PLANE_MCP_WRAPPER_FILE="$REPO_ROOT/scripts/plane-mcp-stdio-wrapper.py"

if [[ "${1:-}" == "--rebuild" ]]; then
  SAFE_LLM_REBUILD=1
  shift
fi

HOST_WORKSPACE="$(pwd)"
PROJECT_NAME="$(basename "$HOST_WORKSPACE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
IMAGE="safe-llm-sandbox"
CONTAINER_HOME="${DEV_CONTAINER_HOME:-/home/node}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONTAINER_DIR="${CODEX_CONTAINER_DIR:-/home/node/.codex}"
NODE_MODULES_VOLUME="${DEV_CONTAINER_NODE_MODULES_VOLUME:-${PROJECT_NAME}-node-modules}"
UV_CACHE_DIR_CONTAINER="${UV_CACHE_DIR_CONTAINER:-/tmp/uv-cache}"
UV_TOOL_DIR_CONTAINER="${UV_TOOL_DIR_CONTAINER:-/tmp/uv-tools}"
PLANE_MCP_WRAPPER_CONTAINER="${PLANE_MCP_WRAPPER_CONTAINER:-/tmp/plane-mcp-stdio-wrapper.py}"
CLAUDE_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-config.XXXXXX")"
CODEX_PLANE_API_KEY_EFFECTIVE="${CODEX_PLANE_API_KEY:-${PLANE_API_KEY:-}}"
CLAUDE_PLANE_API_KEY_EFFECTIVE="${CLAUDE_PLANE_API_KEY:-${PLANE_API_KEY:-}}"
register_cleanup_file "$CLAUDE_CONFIG_FILE"
CHROME_DEVTOOLS_PORT="${CHROME_DEVTOOLS_PORT:-9222}"
DEVTOOLS_PROXY_PORT="${DEVTOOLS_PROXY_PORT:-9223}"
CODEX_SANDBOX_DEVELOPER_INSTRUCTIONS="${CODEX_SANDBOX_DEVELOPER_INSTRUCTIONS:-When browser automation is needed, prefer the chrome-devtools MCP server directly when its tools are available. Do not route browser work through the Browser plugin or browser skill unless a higher-priority instruction explicitly requires it.}"
SSH_ARGS=()
setup_github_auth_args

# Paths under $HOME/.codex where bundled subagent prompts are staged so the
# parent bind mount carries them into the container (see below for rationale).
STAGED_AGENT_PATHS=()
STAGED_CREDENTIALS_PATH=""

cleanup() {
  local staged_agent_path
  for staged_agent_path in "${STAGED_AGENT_PATHS[@]}"; do
    if [[ -f "$staged_agent_path" ]]; then
      rm -f -- "$staged_agent_path"
    fi
  done
  sandbox_cleanup
}
trap cleanup EXIT

setup_ssh_args "$CONTAINER_HOME"
setup_terminal_args
ensure_image_current "$IMAGE" "$REPO_ROOT" both
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

if [[ -n "$CODEX_PLANE_API_KEY_EFFECTIVE" && -n "${PLANE_WORKSPACE_SLUG:-}" ]]; then
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

# Register bundled subagents as standalone custom-agent TOML files. The parent
# $CODEX_DIR bind mount carries them into the container, and cleanup removes
# them from the host after the session.
mkdir -p "$CODEX_DIR/agents"
mkdir -p "$HOME/.claude/agents"

if [[ -f "$HOME/.claude.json" ]]; then
  cp "$HOME/.claude.json" "$CLAUDE_CONFIG_FILE"
else
  printf '{}\n' > "$CLAUDE_CONFIG_FILE"
fi
if [[ -n "$CLAUDE_PLANE_API_KEY_EFFECTIVE" && -n "${PLANE_WORKSPACE_SLUG:-}" ]]; then
  PLANE_MCP_ENABLED=true
else
  PLANE_MCP_ENABLED=false
fi
jq \
  --arg browser_url "$DEVTOOLS_BROWSER_URL" \
  --argjson plane_enabled "$PLANE_MCP_ENABLED" \
  --arg plane_wrapper "$PLANE_MCP_WRAPPER_CONTAINER" \
  --arg uv_cache_dir "$UV_CACHE_DIR_CONTAINER" \
  --arg uv_tool_dir "$UV_TOOL_DIR_CONTAINER" \
  --arg plane_tool_groups "${PLANE_MCP_TOOL_GROUPS:-work_items,work_item_comments,states}" \
  '
  def rewrite_args($url):
      [(. // [])[] | select(. != "-y" and . != "chrome-devtools-mcp" and . != "chrome-devtools-mcp@latest")]
      | map(if type == "string" and startswith("--browser-url=") then "--browser-url=\($url)" else . end)
      | if any(.[]; type == "string" and startswith("--browser-url=")) then . else . + ["--browser-url=\($url)"] end;
  def normalize_devtools($url):
      .command = "chrome-devtools-mcp"
      | .args = (.args | rewrite_args($url));
  def normalize_plane:
      .command = "uvx"
      | .args = ["--from", "plane-mcp-server", "python", $plane_wrapper, "stdio"]
      | .env = ((.env // {}) + {
          "UV_CACHE_DIR": $uv_cache_dir,
          "UV_TOOL_DIR": $uv_tool_dir,
          "PLANE_MCP_TOOL_GROUPS": $plane_tool_groups
        });
  .mcpServers = ((.mcpServers // {}))
  | .mcpServers["chrome-devtools"] = ((.mcpServers["chrome-devtools"] // {}) | normalize_devtools($browser_url))
  | if $plane_enabled then
      .mcpServers["plane"] = ((.mcpServers["plane"] // {}) | normalize_plane)
    else
      del(.mcpServers["plane"])
    end
  | if (.projects? and (.projects | type == "object")) then
      .projects |= with_entries(
          if (.value.mcpServers? and .value.mcpServers["chrome-devtools"]?) then
              .value.mcpServers["chrome-devtools"] |= normalize_devtools($browser_url)
          else
              .
          end
      )
    else
      .
    end
' "$CLAUDE_CONFIG_FILE" > "${CLAUDE_CONFIG_FILE}.tmp"
mv "${CLAUDE_CONFIG_FILE}.tmp" "$CLAUDE_CONFIG_FILE"

if [[ "$HOST_OS" == "Darwin" && ! -f "$HOME/.claude/.credentials.json" ]]; then
  STAGED_CREDENTIALS_PATH="$HOME/.claude/.credentials.json"
  register_cleanup_file "$STAGED_CREDENTIALS_PATH"
  (umask 077 && : > "$STAGED_CREDENTIALS_PATH")
  if ! security find-generic-password -s "Claude Code-credentials" -w \
      > "$STAGED_CREDENTIALS_PATH" 2>/dev/null; then
    echo "Could not stage Claude Code credentials for optional safe-claude-review." >&2
    echo "Run 'claude login' on the host first if this Codex session needs to call Claude." >&2
  fi
fi

stage_codex_agent() {
  local source_file="$1"
  local target_file="$2"
  local codex_name="$3"
  local codex_description="$4"

  python3 - "$source_file" "$target_file" "$codex_name" "$codex_description" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
name = sys.argv[3]
description = sys.argv[4]
instructions = source.read_text()
if instructions.startswith("---\n"):
    _, separator, body = instructions.partition("\n---\n")
    if separator:
        instructions = body.lstrip()
target.write_text(
    f"name = {json.dumps(name)}\n"
    f"description = {json.dumps(description)}\n"
    'model = "gpt-5.4-mini"\n'
    f'developer_instructions = {json.dumps(instructions)}\n'
)
PY
  STAGED_AGENT_PATHS+=("$target_file")
}

stage_codex_agent \
  "$DEVOPS_AGENT_FILE" \
  "$CODEX_DIR/agents/devops.toml" \
  "devops" \
  "Devops-only subagent. Use for CI/CD, deployments, infra, Docker/K8s, observability, secrets, release engineering."

stage_codex_agent \
  "$MANAGER_AGENT_FILE" \
  "$CODEX_DIR/agents/manager.toml" \
  "manager" \
  "Plane manager subagent. Use for querying tickets, updating work items, adding comments, and changing Plane states."

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
  -v "$HOME/.claude":/home/claude/.claude \
  -v "$CLAUDE_CONFIG_FILE":/home/claude/.claude.json \
  -v "$DEVOPS_AGENT_FILE":/home/claude/.claude/agents/devops.md:ro \
  -v "$MANAGER_AGENT_FILE":/home/claude/.claude/agents/manager.md:ro \
  -v "$PLANE_MCP_WRAPPER_FILE:$PLANE_MCP_WRAPPER_CONTAINER:ro" \
  ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} \
  ${PASSWD_ARGS[@]+"${PASSWD_ARGS[@]}"} \
  "${TERMINAL_ARGS[@]}" \
  -e HOME="$CONTAINER_HOME" \
  -e CODEX_HOME="$CODEX_CONTAINER_DIR" \
  -e CODEX_CONTAINER_HOME="$CONTAINER_HOME" \
  -e NPM_CONFIG_CACHE=/tmp/npm-cache \
  -e UV_CACHE_DIR="$UV_CACHE_DIR_CONTAINER" \
  -e UV_TOOL_DIR="$UV_TOOL_DIR_CONTAINER" \
  -e PLANE_MCP_TOOL_GROUPS="${PLANE_MCP_TOOL_GROUPS:-work_items,work_item_comments,states}" \
  -e HCLOUD_TOKEN="${HCLOUD_TOKEN:-}" \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
  -e CLAUDE_PERMISSION_ARGS="${CLAUDE_PERMISSION_ARGS:---dangerously-skip-permissions}" \
  -e CODEX_LINEAR_API_KEY="${CODEX_LINEAR_API_KEY:-}" \
  -e CLAUDE_LINEAR_API_KEY="${CLAUDE_LINEAR_API_KEY:-}" \
  -e CODEX_PLANE_API_KEY="${CODEX_PLANE_API_KEY:-}" \
  -e CLAUDE_PLANE_API_KEY="${CLAUDE_PLANE_API_KEY:-}" \
  -e PLANE_BASE_URL="${PLANE_BASE_URL:-}" \
  -e PLANE_API_KEY="${PLANE_API_KEY:-}" \
  -e PLANE_WORKSPACE_SLUG="${PLANE_WORKSPACE_SLUG:-}" \
  "${GITHUB_AUTH_ARGS[@]}" \
  -v "$NODE_MODULES_VOLUME:$HOST_WORKSPACE/node_modules" \
  --user "$(id -u):$(id -g)" \
  "$IMAGE" bash -lc '
    if [[ -n "${CODEX_LINEAR_API_KEY:-}" ]]; then
      export LINEAR_API_KEY="$CODEX_LINEAR_API_KEY"
    else
      unset LINEAR_API_KEY
    fi
    if [[ -n "${CODEX_PLANE_API_KEY:-}" ]]; then
      export PLANE_API_KEY="$CODEX_PLANE_API_KEY"
    elif [[ -z "${PLANE_API_KEY:-}" ]]; then
      unset PLANE_API_KEY
    fi
    exec "$@"
  ' bash "${CONTAINER_CMD[@]}"
