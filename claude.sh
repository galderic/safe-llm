#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
source "$REPO_ROOT/lib/sandbox.sh"
readonly IMAGE="safe-llm-sandbox"

if [[ "${1:-}" == "--rebuild" ]]; then
    SAFE_LLM_REBUILD=1
    shift
fi

HOST_WORKSPACE="$(pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONTAINER_DIR="${CODEX_CONTAINER_DIR:-/home/node/.codex}"
CHROME_DEVTOOLS_PORT="${CHROME_DEVTOOLS_PORT:-9222}"
DEVTOOLS_PROXY_PORT="${DEVTOOLS_PROXY_PORT:-9222}"
UV_CACHE_DIR_CONTAINER="${UV_CACHE_DIR_CONTAINER:-/tmp/uv-cache}"
UV_TOOL_DIR_CONTAINER="${UV_TOOL_DIR_CONTAINER:-/tmp/uv-tools}"
GITHUB_MCP_TOOLSETS="${GITHUB_MCP_TOOLSETS:-context,issues,pull_requests,projects}"
CLAUDE_PERMISSION_ARGS="${CLAUDE_PERMISSION_ARGS:---dangerously-skip-permissions}"
if [[ -z "${CLAUDE_GITHUB_TOKEN:-}" ]]; then
    echo "CLAUDE_GITHUB_TOKEN is required to launch the Claude sandbox." >&2
    exit 1
fi
CLAUDE_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-config.XXXXXX")"
register_cleanup_file "$CLAUDE_CONFIG_FILE"
setup_github_auth_args

# Path under $HOME/.claude where we stage Keychain-extracted credentials on
# macOS (see the credentials block further below). Removed on exit so the
# host's normal Keychain-based auth state is left untouched.
STAGED_CREDENTIALS_PATH=""

cleanup() {
    sandbox_cleanup
}
trap cleanup EXIT

ensure_image_current "$IMAGE" "$REPO_ROOT" both
setup_devtools "$IMAGE" "$CHROME_DEVTOOLS_PORT" "$DEVTOOLS_PROXY_PORT"
ensure_chrome_devtools

mkdir -p "$CODEX_DIR"

if [[ -f "$HOME/.claude.json" ]]; then
    cp "$HOME/.claude.json" "$CLAUDE_CONFIG_FILE"
else
    printf '{}\n' > "$CLAUDE_CONFIG_FILE"
fi
GITHUB_MCP_ENABLED=true
jq \
    --arg browser_url "$DEVTOOLS_BROWSER_URL" \
    --argjson github_enabled "$GITHUB_MCP_ENABLED" \
    --arg github_toolsets "$GITHUB_MCP_TOOLSETS" \
    '
    def rewrite_args($url):
        [(. // [])[] | select(. != "-y" and . != "chrome-devtools-mcp" and . != "chrome-devtools-mcp@latest")]
        | map(if type == "string" and startswith("--browser-url=") then "--browser-url=\($url)" else . end)
        | if any(.[]; type == "string" and startswith("--browser-url=")) then . else . + ["--browser-url=\($url)"] end;
    def normalize_devtools($url):
        .command = "chrome-devtools-mcp"
        | .args = (.args | rewrite_args($url));
    def normalize_github:
        .command = "github-mcp-server"
        | .args = ["stdio"]
        | .env = ((.env // {}) + {
            "GITHUB_TOOLSETS": $github_toolsets
          });
    .mcpServers = ((.mcpServers // {}))
    | .mcpServers["chrome-devtools"] = ((.mcpServers["chrome-devtools"] // {}) | normalize_devtools($browser_url))
    | if $github_enabled then
        .mcpServers["github"] = ((.mcpServers["github"] // {}) | normalize_github)
      else
        del(.mcpServers["github"])
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

DOCKER_MOUNT_ARGS=(
    -v "$HOST_WORKSPACE:$HOST_WORKSPACE"
    -v "$HOME/.claude":/home/claude/.claude
    -v "$CODEX_DIR:$CODEX_CONTAINER_DIR"
    -v "$CLAUDE_CONFIG_FILE":/home/claude/.claude.json
)

# Provide subscription-based OAuth credentials to the Linux container.
#
# Linux: the Claude CLI persists credentials to ~/.claude/.credentials.json,
# which gets carried in by the $HOME/.claude bind mount above. Nothing to do.
#
# macOS: the CLI stores credentials in the login Keychain under
# "Claude Code-credentials". The container can't read the Keychain, so we
# materialize the same JSON blob inside $HOME/.claude/.credentials.json
# (where the Linux CLI would look) and let the parent bind mount carry it
# in. Writing it as a tempfile and nesting a mount on top doesn't work on
# Docker Desktop: virtiofs refuses to create a mountpoint inside an
# already-virtiofs-mounted directory. The cleanup trap removes the file on
# exit, so the host's Keychain-based auth state is left untouched.
if [[ "$HOST_OS" == "Darwin" && ! -f "$HOME/.claude/.credentials.json" ]]; then
    STAGED_CREDENTIALS_PATH="$HOME/.claude/.credentials.json"
    register_cleanup_file "$STAGED_CREDENTIALS_PATH"
    (umask 077 && : > "$STAGED_CREDENTIALS_PATH")
    if ! security find-generic-password -s "Claude Code-credentials" -w \
            > "$STAGED_CREDENTIALS_PATH" 2>/dev/null; then
        echo "Could not read 'Claude Code-credentials' from the login Keychain." >&2
        echo "Run 'claude login' on the host first, or export ANTHROPIC_API_KEY (note: API-key billing, not subscription)." >&2
        exit 1
    fi
fi

setup_ssh_args /home/claude
setup_terminal_args

if [[ -f "$HOME/.gitconfig" ]]; then
    DOCKER_MOUNT_ARGS+=(-v "$HOME/.gitconfig":/home/claude/.gitconfig:ro)
fi

setup_host_passwd_args "$IMAGE" /home/claude claude

docker run -it --rm \
    --add-host=host.docker.internal:host-gateway \
    --user "$(id -u):$(id -g)" \
    -w "$HOST_WORKSPACE" \
    -e HOME=/home/claude \
    "${DOCKER_MOUNT_ARGS[@]}" \
    ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} \
    ${PASSWD_ARGS[@]+"${PASSWD_ARGS[@]}"} \
    "${TERMINAL_ARGS[@]}" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e CLAUDE_PERMISSION_ARGS="$CLAUDE_PERMISSION_ARGS" \
    -e CODEX_HOME="$CODEX_CONTAINER_DIR" \
    -e CODEX_CONTAINER_HOME=/home/node \
    -e CODEX_LINEAR_API_KEY="${CODEX_LINEAR_API_KEY:-}" \
    -e CLAUDE_LINEAR_API_KEY="${CLAUDE_LINEAR_API_KEY:-}" \
    -e CODEX_GITHUB_TOKEN="${CODEX_GITHUB_TOKEN:-}" \
    -e CLAUDE_GITHUB_TOKEN="${CLAUDE_GITHUB_TOKEN:-}" \
    -e GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}" \
    -e GITHUB_MCP_TOOLSETS="$GITHUB_MCP_TOOLSETS" \
    -e GITHUB_TOOLSETS="$GITHUB_MCP_TOOLSETS" \
    -e HCLOUD_TOKEN="${HCLOUD_TOKEN:-}" \
    -e UV_CACHE_DIR="$UV_CACHE_DIR_CONTAINER" \
    -e UV_TOOL_DIR="$UV_TOOL_DIR_CONTAINER" \
    "${GITHUB_AUTH_ARGS[@]}" \
    "$IMAGE" \
    bash -lc '# The container is the sandbox boundary; skip Claude Code prompts inside it by default.
        if [[ -n "${CLAUDE_LINEAR_API_KEY:-}" ]]; then
            export LINEAR_API_KEY="$CLAUDE_LINEAR_API_KEY"
        else
            unset LINEAR_API_KEY
        fi
        export GITHUB_PERSONAL_ACCESS_TOKEN="$CLAUDE_GITHUB_TOKEN"
        export GITHUB_TOOLSETS="${GITHUB_MCP_TOOLSETS}"
        read -r -a permission_args <<< "${CLAUDE_PERMISSION_ARGS}"
        exec claude "${permission_args[@]}" "$@"' bash "$@"
