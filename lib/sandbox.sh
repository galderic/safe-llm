#!/usr/bin/env bash

# Shared helpers for the tool-specific sandbox launchers. This file is meant
# to be sourced by scripts that already enabled strict mode.

HOST_OS="${HOST_OS:-$(uname -s)}"
SANDBOX_CLEANUP_FILES=()

register_cleanup_file() {
  SANDBOX_CLEANUP_FILES+=("$1")
}

sandbox_cleanup() {
  if [[ -n "${DEVTOOLS_PROXY_PID:-}" ]]; then
    kill "$DEVTOOLS_PROXY_PID" >/dev/null 2>&1 || true
  fi

  local path
  for path in "${SANDBOX_CLEANUP_FILES[@]}"; do
    if [[ -n "$path" && -f "$path" ]]; then
      rm -f -- "$path"
    fi
  done
}

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
    local ts="${1%%.*}"
    ts="${ts%Z}"
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s
  fi
}

ensure_image_current() {
  local image="$1"
  local dockerfile_dir="$2"
  local target="${3:-}"
  local image_created_at
  local image_created_epoch
  local dockerfile_epoch
  local image_needs_build
  local build_args=()

  if [[ -n "$target" ]]; then
    build_args+=(--target "$target")
  fi

  if [[ "${SAFE_LLM_REBUILD:-}" == 1 ]]; then
    image_needs_build=1
  else
    image_created_at="$(docker image inspect --format '{{.Created}}' "$image" 2>/dev/null || true)"
    if [[ -z "$image_created_at" ]]; then
      image_needs_build=1
    else
      image_created_epoch="$(iso_to_epoch "$image_created_at")"
      dockerfile_epoch="$(file_mtime "$dockerfile_dir/Dockerfile")"
      local dependency
      for dependency in \
        "$dockerfile_dir/scripts/safe-claude-review" \
        "$dockerfile_dir/scripts/safe-codex-review"; do
        if [[ -f "$dependency" && "$(file_mtime "$dependency")" -gt "$dockerfile_epoch" ]]; then
          dockerfile_epoch="$(file_mtime "$dependency")"
        fi
      done
      if [[ "$dockerfile_epoch" -gt "$image_created_epoch" ]]; then
        image_needs_build=1
      else
        image_needs_build=0
      fi
    fi
  fi

  if [[ "$image_needs_build" == 1 ]]; then
    if [[ "${SAFE_LLM_REBUILD:-}" == 1 ]]; then
      docker build --pull --no-cache "${build_args[@]}" -t "$image" "$dockerfile_dir"
    else
      docker build "${build_args[@]}" -t "$image" "$dockerfile_dir"
    fi
  fi
}

setup_github_auth_args() {
  # shellcheck disable=SC2034,SC2016
  GITHUB_AUTH_ARGS=(
    -e GH_TOKEN
    -e GITHUB_TOKEN
    -e GIT_CONFIG_COUNT=1
    -e GIT_CONFIG_KEY_0=credential.https://github.com.helper
    -e 'GIT_CONFIG_VALUE_0=!f() { test "$1" = get || exit 0; token="${GITHUB_PERSONAL_ACCESS_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"; test -n "$token" || exit 0; printf "username=x-access-token\npassword=%s\n" "$token"; }; f'
  )
}

setup_terminal_args() {
  local term="${SAFE_LLM_TERM:-${TERM:-xterm-256color}}"
  if [[ -z "$term" || "$term" == "dumb" || "$term" == "xterm-ghostty" ]]; then
    term="xterm-256color"
  fi

  local locale="${SAFE_LLM_LANG:-C.UTF-8}"
  local lc_all="${SAFE_LLM_LC_ALL:-$locale}"

  # shellcheck disable=SC2034
  TERMINAL_ARGS=(
    -e "TERM=$term"
    -e "COLORTERM=${COLORTERM:-truecolor}"
    -e "LANG=$locale"
    -e "LC_ALL=$lc_all"
  )

  if [[ -n "${TERM_PROGRAM:-}" ]]; then
    TERMINAL_ARGS+=(-e "TERM_PROGRAM=$TERM_PROGRAM")
  fi
}

# Portable in-place sed. BSD sed (macOS) requires an explicit suffix argument
# after -i; passing '' means no backup file.
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

setup_ssh_args() {
  local container_home="$1"

  SSH_ARGS=()
  if [[ "$HOST_OS" == "Darwin" ]]; then
    # Docker Desktop synthesizes the socket as root:root 0660, so the
    # --user-mapped container uid needs the root group to open it.
    SSH_ARGS=(
      -v /run/host-services/ssh-auth.sock:/ssh-agent
      -e SSH_AUTH_SOCK=/ssh-agent
      --group-add 0
    )
  elif [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
    SSH_ARGS=(
      -v "$SSH_AUTH_SOCK:/ssh-agent"
      -e SSH_AUTH_SOCK=/ssh-agent
    )
  fi

  if [[ -f "$HOME/.ssh/known_hosts" ]]; then
    SSH_ARGS+=(-v "$HOME/.ssh/known_hosts:$container_home/.ssh/known_hosts:ro")
  fi
}

setup_host_passwd_args() {
  local image="$1"
  local container_home="$2"
  local prefix="$3"

  PASSWD_ARGS=()
  HOST_PASSWD_FILE=""
  if [[ "$HOST_OS" == "Darwin" ]]; then
    HOST_PASSWD_FILE="$(mktemp "${TMPDIR:-/tmp}/${prefix}-passwd.XXXXXX")"
    docker run --rm "$image" cat /etc/passwd > "$HOST_PASSWD_FILE"
    printf 'hostuser:x:%s:%s:host user:%s:/bin/bash\n' \
      "$(id -u)" "$(id -g)" "$container_home" >> "$HOST_PASSWD_FILE"
    register_cleanup_file "$HOST_PASSWD_FILE"
    # shellcheck disable=SC2034
    PASSWD_ARGS=(-v "$HOST_PASSWD_FILE:/etc/passwd:ro")
  fi
}

# Pick how the container reaches the host's Chrome DevTools endpoint.
#
# Linux: the kernel bridge IP exposed via `--add-host=host.docker.internal:
# host-gateway` is a real interface on the host, so we run a socat proxy bound
# to that IP that forwards to Chrome on 127.0.0.1.
#
# macOS (Docker Desktop): the gateway IP lives inside Docker's VM and is not
# bindable on the host. Docker Desktop's host.docker.internal NATs into the
# host loopback, so no proxy is needed. Chrome rejects DevTools requests whose
# Host header is a non-localhost hostname, so the MCP browser URL uses Docker's
# resolved IPv4 address instead of host.docker.internal.
setup_devtools() {
  local image="$1"
  local chrome_port="$2"
  local proxy_port="$3"

  CHROME_DEVTOOLS_PORT="$chrome_port"
  DEVTOOLS_PROXY_PORT="$proxy_port"

  if [[ "$HOST_OS" == "Linux" ]]; then
    HOST_GATEWAY_IP="$(
      docker run --rm \
        --add-host=host.docker.internal:host-gateway \
        "$image" \
        getent ahostsv4 host.docker.internal | awk '{print $1; exit}'
    )"
    DEVTOOLS_HOST_FOR_CONTAINER="$HOST_GATEWAY_IP"
    DEVTOOLS_PORT_FOR_CONTAINER="$DEVTOOLS_PROXY_PORT"
    HOST_PROBE_URL="http://${HOST_GATEWAY_IP}:${DEVTOOLS_PROXY_PORT}/json/version"

    socat \
      "TCP-LISTEN:${DEVTOOLS_PROXY_PORT},fork,reuseaddr,bind=${HOST_GATEWAY_IP}" \
      "TCP:127.0.0.1:${CHROME_DEVTOOLS_PORT}" &
    DEVTOOLS_PROXY_PID="$!"
  elif [[ "$HOST_OS" == "Darwin" ]]; then
    DOCKER_DESKTOP_HOST_IP="$(
      docker run --rm \
        "$image" \
        getent ahostsv4 host.docker.internal | awk '{print $1; exit}'
    )"
    DEVTOOLS_HOST_FOR_CONTAINER="${DOCKER_DESKTOP_HOST_IP:-host.docker.internal}"
    DEVTOOLS_PORT_FOR_CONTAINER="$CHROME_DEVTOOLS_PORT"
    HOST_PROBE_URL="http://127.0.0.1:${CHROME_DEVTOOLS_PORT}/json/version"
  else
    DEVTOOLS_HOST_FOR_CONTAINER="host.docker.internal"
    DEVTOOLS_PORT_FOR_CONTAINER="$CHROME_DEVTOOLS_PORT"
    HOST_PROBE_URL="http://127.0.0.1:${CHROME_DEVTOOLS_PORT}/json/version"
  fi

  # shellcheck disable=SC2034
  DEVTOOLS_BROWSER_URL="http://${DEVTOOLS_HOST_FOR_CONTAINER}:${DEVTOOLS_PORT_FOR_CONTAINER}"
}

probe_devtools() {
  local _
  for _ in {1..20}; do
    if curl -fsS "$HOST_PROBE_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Launch Chrome with remote debugging on $CHROME_DEVTOOLS_PORT. A dedicated
# --user-data-dir is required because Chrome forwards command-line flags to any
# already-running instance and silently ignores --remote-debugging-port when it
# does; a separate profile dir forces a fresh process that opens the debug port.
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

ensure_chrome_devtools() {
  if ! probe_devtools; then
    echo "Chrome DevTools not reachable at ${HOST_PROBE_URL}; starting Chrome..." >&2
    if ! start_chrome; then
      exit 1
    fi

    local devtools_ready=0
    for _ in {1..100}; do
      if curl -fsS "$HOST_PROBE_URL" >/dev/null 2>&1; then
        devtools_ready=1
        break
      fi
      sleep 0.2
    done

    if [[ "$devtools_ready" != 1 ]]; then
      echo "Chrome DevTools still not reachable at ${HOST_PROBE_URL} after launching Chrome." >&2
      if [[ "$HOST_OS" == "Linux" ]]; then
        echo "If Chrome is listening on all interfaces, set DEVTOOLS_PROXY_PORT to a free port and update the MCP browser URL to match." >&2
      fi
      exit 1
    fi
  fi
}
