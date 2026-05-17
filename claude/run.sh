#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE="claude-sandbox"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST_WORKSPACE="$(pwd)"
CHROME_DEVTOOLS_PORT="${CHROME_DEVTOOLS_PORT:-9222}"
DEVTOOLS_PROXY_PORT="${DEVTOOLS_PROXY_PORT:-9222}"
CLAUDE_PERMISSION_ARGS="${CLAUDE_PERMISSION_ARGS:---dangerously-skip-permissions}"
CLAUDE_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-config.XXXXXX.json")"
GITHUB_AUTH_ARGS=(
    -e GH_TOKEN
    -e GITHUB_TOKEN
    -e GIT_CONFIG_COUNT=1
    -e GIT_CONFIG_KEY_0=credential.https://github.com.helper
    -e 'GIT_CONFIG_VALUE_0=!f() { test "$1" = get || exit 0; token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"; test -n "$token" || exit 0; printf "username=x-access-token\npassword=%s\n" "$token"; }; f'
)

cleanup() {
    if [[ -n "${DEVTOOLS_PROXY_PID:-}" ]]; then
        kill "$DEVTOOLS_PROXY_PID" >/dev/null 2>&1 || true
    fi
    rm -f -- "$CLAUDE_CONFIG_FILE"
}
trap cleanup EXIT

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

HOST_GATEWAY_IP="$(
    docker run --rm \
        --add-host=host.docker.internal:host-gateway \
        "$IMAGE" \
        getent hosts host.docker.internal | awk '{print $1; exit}'
)"

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
    echo "If Chrome is listening on all interfaces, set DEVTOOLS_PROXY_PORT to a free port and update the MCP browser URL to match." >&2
    exit 1
fi

# Ensure the user-level Claude agents dir exists on the host so we can
# overlay the devops subagent definition into the container via a nested
# bind mount (the parent `~/.claude` is already mounted further down).
mkdir -p "$HOME/.claude/agents"

cp "$HOME/.claude.json" "$CLAUDE_CONFIG_FILE"
jq --arg browser_url "http://${HOST_GATEWAY_IP}:${DEVTOOLS_PROXY_PORT}" '
    def rewrite_args($url):
        [(. // [])[] | select(. != "-y" and . != "chrome-devtools-mcp" and . != "chrome-devtools-mcp@latest")]
        | map(if type == "string" and startswith("--browser-url=") then "--browser-url=\($url)" else . end)
        | if any(.[]; type == "string" and startswith("--browser-url=")) then . else . + ["--browser-url=\($url)"] end;
    def normalize_devtools($url):
        .command = "chrome-devtools-mcp"
        | .args = (.args | rewrite_args($url));
    if (.mcpServers? and .mcpServers["chrome-devtools"]?) then
        .mcpServers["chrome-devtools"] |= normalize_devtools($browser_url)
    else
        .
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

docker run -it --rm \
    --add-host=host.docker.internal:host-gateway \
    --user "$(id -u):$(id -g)" \
    -v "$HOST_WORKSPACE:$HOST_WORKSPACE" \
    -w "$HOST_WORKSPACE" \
    -v "$HOME/.claude":/home/claude/.claude \
    -v "$HOME/.claude/.credentials.json":/home/claude/.claude/.credentials.json:ro \
    -v "$CLAUDE_CONFIG_FILE":/home/claude/.claude.json \
    -v "$SCRIPT_DIR/agents/devops.md":/home/claude/.claude/agents/devops.md:ro \
    -v "${SSH_AUTH_SOCK:-/dev/null}":/ssh-agent \
    -v "$HOME/.gitconfig":/home/claude/.gitconfig:ro \
    -e SSH_AUTH_SOCK=/ssh-agent \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e CLAUDE_PERMISSION_ARGS="$CLAUDE_PERMISSION_ARGS" \
    "${GITHUB_AUTH_ARGS[@]}" \
    "$IMAGE" \
    bash -lc '# The container is the sandbox boundary; skip Claude Code prompts inside it by default.
        read -r -a permission_args <<< "${CLAUDE_PERMISSION_ARGS}"
        exec claude "${permission_args[@]}" "$@"' bash "$@"
