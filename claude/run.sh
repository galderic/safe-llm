#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE="claude-sandbox"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST_WORKSPACE="$(pwd)"
CHROME_DEVTOOLS_PORT="${CHROME_DEVTOOLS_PORT:-9222}"
DEVTOOLS_PROXY_PORT="${DEVTOOLS_PROXY_PORT:-9222}"
CLAUDE_PERMISSION_ARGS="${CLAUDE_PERMISSION_ARGS:---dangerously-skip-permissions}"
CLAUDE_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-config.XXXXXX")"
GITHUB_AUTH_ARGS=(
    -e GH_TOKEN
    -e GITHUB_TOKEN
    -e GIT_CONFIG_COUNT=1
    -e GIT_CONFIG_KEY_0=credential.https://github.com.helper
    -e 'GIT_CONFIG_VALUE_0=!f() { test "$1" = get || exit 0; token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"; test -n "$token" || exit 0; printf "username=x-access-token\npassword=%s\n" "$token"; }; f'
)

# Path under $HOME/.claude where we stage Keychain-extracted credentials on
# macOS (see the credentials block further below). Removed on exit so the
# host's normal Keychain-based auth state is left untouched.
STAGED_CREDENTIALS_PATH=""

cleanup() {
    if [[ -n "${DEVTOOLS_PROXY_PID:-}" ]]; then
        kill "$DEVTOOLS_PROXY_PID" >/dev/null 2>&1 || true
    fi
    rm -f -- "$CLAUDE_CONFIG_FILE"
    if [[ -n "$STAGED_CREDENTIALS_PATH" && -f "$STAGED_CREDENTIALS_PATH" ]]; then
        rm -f -- "$STAGED_CREDENTIALS_PATH"
    fi
}
trap cleanup EXIT

# Portable mtime / ISO-8601-to-epoch helpers (GNU coreutils on Linux,
# BSD tools on macOS).
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
        # BSD date: strip fractional seconds and trailing 'Z', parse as UTC.
        local ts="${1%%.*}"
        ts="${ts%Z}"
        TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s
    fi
}

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

HOST_OS="$(uname -s)"

# Pick how the container reaches the host's Chrome DevTools endpoint.
#
# Linux: the kernel bridge IP exposed via `--add-host=host.docker.internal:
# host-gateway` is a real interface on the host, so we can run a socat
# proxy bound to that IP that forwards to Chrome on 127.0.0.1. The
# container then connects to that IP:port.
#
# macOS (Docker Desktop): the gateway IP lives inside Docker's VM and is
# not bindable on the host. Docker Desktop instead provides built-in
# `host.docker.internal` resolution that NATs into the host's loopback,
# so we skip the proxy and let the container connect directly to
# host.docker.internal:<chrome port>.
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

    socat \
        "TCP-LISTEN:${DEVTOOLS_PROXY_PORT},fork,reuseaddr,bind=${HOST_GATEWAY_IP}" \
        "TCP:127.0.0.1:${CHROME_DEVTOOLS_PORT}" &
    DEVTOOLS_PROXY_PID="$!"
else
    DEVTOOLS_HOST_FOR_CONTAINER="host.docker.internal"
    DEVTOOLS_PORT_FOR_CONTAINER="$CHROME_DEVTOOLS_PORT"
    HOST_PROBE_URL="http://127.0.0.1:${CHROME_DEVTOOLS_PORT}/json/version"
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
        if [[ "$HOST_OS" == "Linux" ]]; then
            echo "If Chrome is listening on all interfaces, set DEVTOOLS_PROXY_PORT to a free port and update the MCP browser URL to match." >&2
        fi
        exit 1
    fi
fi

DEVTOOLS_BROWSER_URL="http://${DEVTOOLS_HOST_FOR_CONTAINER}:${DEVTOOLS_PORT_FOR_CONTAINER}"

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
    (umask 077 && : > "$STAGED_CREDENTIALS_PATH")
    if ! security find-generic-password -s "Claude Code-credentials" -w \
            > "$STAGED_CREDENTIALS_PATH" 2>/dev/null; then
        echo "Could not read 'Claude Code-credentials' from the login Keychain." >&2
        echo "Run 'claude login' on the host first, or export ANTHROPIC_API_KEY (note: API-key billing, not subscription)." >&2
        exit 1
    fi
fi

if [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
    DOCKER_MOUNT_ARGS+=(-v "$SSH_AUTH_SOCK":/ssh-agent)
    SSH_ENV_ARGS=(-e SSH_AUTH_SOCK=/ssh-agent)
else
    SSH_ENV_ARGS=()
fi

if [[ -f "$HOME/.gitconfig" ]]; then
    DOCKER_MOUNT_ARGS+=(-v "$HOME/.gitconfig":/home/claude/.gitconfig:ro)
fi

docker run -it --rm \
    --add-host=host.docker.internal:host-gateway \
    --user "$(id -u):$(id -g)" \
    -w "$HOST_WORKSPACE" \
    -e HOME=/home/claude \
    "${DOCKER_MOUNT_ARGS[@]}" \
    ${SSH_ENV_ARGS[@]+"${SSH_ENV_ARGS[@]}"} \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e CLAUDE_PERMISSION_ARGS="$CLAUDE_PERMISSION_ARGS" \
    "${GITHUB_AUTH_ARGS[@]}" \
    "$IMAGE" \
    bash -lc '# The container is the sandbox boundary; skip Claude Code prompts inside it by default.
        read -r -a permission_args <<< "${CLAUDE_PERMISSION_ARGS}"
        exec claude "${permission_args[@]}" "$@"' bash "$@"
