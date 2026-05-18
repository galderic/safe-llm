#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE="claude-sandbox"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/sandbox.sh"

HOST_WORKSPACE="$(pwd)"
CHROME_DEVTOOLS_PORT="${CHROME_DEVTOOLS_PORT:-9222}"
DEVTOOLS_PROXY_PORT="${DEVTOOLS_PROXY_PORT:-9222}"
CLAUDE_PERMISSION_ARGS="${CLAUDE_PERMISSION_ARGS:---dangerously-skip-permissions}"
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

ensure_image_current "$IMAGE" "$SCRIPT_DIR"
setup_devtools "$IMAGE" "$CHROME_DEVTOOLS_PORT" "$DEVTOOLS_PROXY_PORT"
ensure_chrome_devtools

# Ensure the user-level Claude agents dir exists on the host so we can
# overlay the devops subagent definition into the container via a nested
# bind mount (the parent `~/.claude` is already mounted further down).
mkdir -p "$HOME/.claude/agents"

cp "$HOME/.claude.json" "$CLAUDE_CONFIG_FILE"
jq --arg browser_url "$DEVTOOLS_BROWSER_URL" '
    def rewrite_args($url):
        [(. // [])[] | select(. != "-y" and . != "chrome-devtools-mcp" and . != "chrome-devtools-mcp@latest")]
        | map(if type == "string" and startswith("--browser-url=") then "--browser-url=\($url)" else . end)
        | if any(.[]; type == "string" and startswith("--browser-url=")) then . else . + ["--browser-url=\($url)"] end;
    def normalize_devtools($url):
        .command = "chrome-devtools-mcp"
        | .args = (.args | rewrite_args($url));
    .mcpServers = ((.mcpServers // {}))
    | .mcpServers["chrome-devtools"] = ((.mcpServers["chrome-devtools"] // {}) | normalize_devtools($browser_url))
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
    -v "$CLAUDE_CONFIG_FILE":/home/claude/.claude.json
    -v "$SCRIPT_DIR/agents/devops.md":/home/claude/.claude/agents/devops.md:ro
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
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e CLAUDE_PERMISSION_ARGS="$CLAUDE_PERMISSION_ARGS" \
    "${GITHUB_AUTH_ARGS[@]}" \
    "$IMAGE" \
    bash -lc '# The container is the sandbox boundary; skip Claude Code prompts inside it by default.
        read -r -a permission_args <<< "${CLAUDE_PERMISSION_ARGS}"
        exec claude "${permission_args[@]}" "$@"' bash "$@"
