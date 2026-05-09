#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE="claude-sandbox"
CHROME_DEVTOOLS_PORT="${CHROME_DEVTOOLS_PORT:-9222}"
DEVTOOLS_PROXY_PORT="${DEVTOOLS_PROXY_PORT:-9222}"
CLAUDE_PERMISSION_ARGS="${CLAUDE_PERMISSION_ARGS:---dangerously-skip-permissions}"

cleanup() {
    if [[ -n "${DEVTOOLS_PROXY_PID:-}" ]]; then
        kill "$DEVTOOLS_PROXY_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

IMAGE_CREATED_AT="$(docker image inspect --format '{{.Created}}' "$IMAGE" 2>/dev/null || true)"
if [[ -z "$IMAGE_CREATED_AT" ]]; then
    IMAGE_NEEDS_BUILD=1
else
    IMAGE_CREATED_EPOCH="$(date -d "$IMAGE_CREATED_AT" +%s)"
    DOCKERFILE_EPOCH="$(stat -c %Y Dockerfile)"
    if [[ "$DOCKERFILE_EPOCH" -gt "$IMAGE_CREATED_EPOCH" ]]; then
        IMAGE_NEEDS_BUILD=1
    else
        IMAGE_NEEDS_BUILD=0
    fi
fi

if [[ "$IMAGE_NEEDS_BUILD" == 1 ]]; then
    docker build -t "$IMAGE" .
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

docker run -it --rm \
    --add-host=host.docker.internal:host-gateway \
    --user "$(id -u):$(id -g)" \
    -v "$(pwd)":/home/claude/workspace \
    -v "$HOME/.claude/.credentials.json":/home/claude/.claude/.credentials.json:ro \
    -v "$HOME/.claude.json":/home/claude/.claude.json \
    -v "${SSH_AUTH_SOCK:-/dev/null}":/ssh-agent \
    -v "$HOME/.gitconfig":/home/claude/.gitconfig:ro \
    -e SSH_AUTH_SOCK=/ssh-agent \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e CLAUDE_PERMISSION_ARGS="$CLAUDE_PERMISSION_ARGS" \
    "$IMAGE" \
    bash -lc '# The container is the sandbox boundary; skip Claude Code prompts inside it by default.
        read -r -a permission_args <<< "${CLAUDE_PERMISSION_ARGS}"
        exec claude "${permission_args[@]}" "$@"' bash "$@"
