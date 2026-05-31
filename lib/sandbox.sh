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
  local pid
  for pid in ${HOST_SERVICE_PROXY_PIDS:-}; do
    kill "$pid" >/dev/null 2>&1 || true
  done

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

load_safe_llm_instructions() {
  local repo_root="$1"
  local instructions_path="${SAFE_LLM_INSTRUCTIONS_FILE:-$repo_root/AGENTS.md}"

  # shellcheck disable=SC2034
  SAFE_LLM_INSTRUCTIONS=""
  if [[ "${SAFE_LLM_INCLUDE_INSTRUCTIONS:-1}" == 0 ]]; then
    return 0
  fi

  if [[ -f "$instructions_path" ]]; then
    # shellcheck disable=SC2034
    SAFE_LLM_INSTRUCTIONS="$(
      printf 'Additional instructions from safe-llm launcher (%s):\n\n' "$instructions_path"
      sed -n '1,$p' "$instructions_path"
    )"
  else
    echo "safe-llm instructions file not found: $instructions_path" >&2
  fi
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

host_port_is_reachable() {
  local host="$1"
  local port="$2"

  if command -v nc >/dev/null 2>&1; then
    nc -z -w 1 "$host" "$port" >/dev/null 2>&1
  elif command -v timeout >/dev/null 2>&1; then
    timeout 1 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

setup_port_forward_args() {
  local ports="${SAFE_LLM_FORWARD_PORTS-3001,5173,4173,8000,8080}"
  local bind_host="${SAFE_LLM_FORWARD_HOST:-127.0.0.1}"

  PORT_FORWARD_ARGS=()
  if [[ -z "$ports" ]]; then
    return 0
  fi

  local port
  local old_ifs="$IFS"
  IFS=,
  for port in $ports; do
    IFS="$old_ifs"
    port="${port//[[:space:]]/}"
    if [[ -z "$port" ]]; then
      IFS=,
      continue
    fi

    if [[ "$port" == *:* ]]; then
      PORT_FORWARD_ARGS+=(-p "$port")
    else
      if host_port_is_reachable "$bind_host" "$port"; then
        echo "Skipping dev-server port ${bind_host}:${port}; it is already in use." >&2
        IFS=,
        continue
      fi

      PORT_FORWARD_ARGS+=(-p "${bind_host}:${port}:${port}")
    fi
    IFS=,
  done
  IFS="$old_ifs"
}

resolve_host_gateway_ip() {
  local image="$1"

  if [[ -z "${HOST_GATEWAY_IP:-}" ]]; then
    HOST_GATEWAY_IP="$(
      docker run --rm \
        --add-host=host.docker.internal:host-gateway \
        "$image" \
        getent ahostsv4 host.docker.internal | awk '{print $1; exit}'
    )"
  fi
}

setup_host_service_proxies() {
  local image="$1"
  local ports="${SAFE_LLM_HOST_PORTS-5432}"

  HOST_SERVICE_PROXY_PIDS=""
  if [[ -z "$ports" || "$HOST_OS" != "Linux" ]]; then
    return 0
  fi

  resolve_host_gateway_ip "$image"

  local port
  local old_ifs="$IFS"
  IFS=,
  for port in $ports; do
    IFS="$old_ifs"
    port="${port//[[:space:]]/}"
    if [[ -z "$port" ]]; then
      IFS=,
      continue
    fi

    if timeout 1 bash -c "</dev/tcp/${HOST_GATEWAY_IP}/${port}" >/dev/null 2>&1; then
      IFS=,
      continue
    fi

    socat \
      "TCP-LISTEN:${port},fork,reuseaddr,bind=${HOST_GATEWAY_IP}" \
      "TCP:127.0.0.1:${port}" &
    HOST_SERVICE_PROXY_PIDS="${HOST_SERVICE_PROXY_PIDS:+$HOST_SERVICE_PROXY_PIDS }$!"
    IFS=,
  done
  IFS="$old_ifs"
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

# Start a host-side TCP proxy. Returns success only after the proxy process is
# still alive, so callers can recover from bind failures without using a dead
# endpoint.
start_tcp_proxy() {
  local bind_host="$1"
  local listen_port="$2"
  local target_host="$3"
  local target_port="$4"
  local stderr_file="$5"
  local proxy_pid

  : > "$stderr_file"
  socat \
    "TCP-LISTEN:${listen_port},fork,reuseaddr,bind=${bind_host}" \
    "TCP:${target_host}:${target_port}" \
    2>>"$stderr_file" &
  proxy_pid="$!"

  sleep 0.1
  if kill -0 "$proxy_pid" >/dev/null 2>&1; then
    DEVTOOLS_PROXY_PID="$proxy_pid"
    return 0
  fi

  wait "$proxy_pid" >/dev/null 2>&1 || true
  return 1
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
    resolve_host_gateway_ip "$image"
    local proxy_stderr
    local port_scan_count="${SAFE_LLM_DEVTOOLS_PROXY_PORT_SCAN:-20}"
    local candidate_port
    local last_port
    local started_proxy=0

    if ! [[ "$port_scan_count" =~ ^[0-9]+$ ]] || [[ "$port_scan_count" -lt 1 ]]; then
      port_scan_count=1
    fi
    proxy_stderr="$(mktemp "${TMPDIR:-/tmp}/safe-llm-devtools-proxy.XXXXXX")"
    register_cleanup_file "$proxy_stderr"

    last_port=$((DEVTOOLS_PROXY_PORT + port_scan_count - 1))
    for ((candidate_port = DEVTOOLS_PROXY_PORT; candidate_port <= last_port; candidate_port++)); do
      if start_tcp_proxy "$HOST_GATEWAY_IP" "$candidate_port" 127.0.0.1 "$CHROME_DEVTOOLS_PORT" "$proxy_stderr"; then
        DEVTOOLS_PROXY_PORT="$candidate_port"
        started_proxy=1
        break
      fi

      if [[ "$candidate_port" -eq "$proxy_port" ]]; then
        echo "DevTools proxy port ${HOST_GATEWAY_IP}:${candidate_port} is unavailable; trying another port." >&2
      fi
    done

    if [[ "$started_proxy" != 1 ]]; then
      echo "Could not start a DevTools proxy on ${HOST_GATEWAY_IP}:${proxy_port}-${last_port}." >&2
      if [[ -s "$proxy_stderr" ]]; then
        tail -n 3 "$proxy_stderr" >&2
      fi
      exit 1
    fi

    if [[ "$DEVTOOLS_PROXY_PORT" != "$proxy_port" ]]; then
      echo "Using DevTools proxy port ${HOST_GATEWAY_IP}:${DEVTOOLS_PROXY_PORT}." >&2
    fi

    DEVTOOLS_HOST_FOR_CONTAINER="$HOST_GATEWAY_IP"
    DEVTOOLS_PORT_FOR_CONTAINER="$DEVTOOLS_PROXY_PORT"
    HOST_PROBE_URL="http://${HOST_GATEWAY_IP}:${DEVTOOLS_PROXY_PORT}/json/version"
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

is_ssh_session() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]]
}

infer_x_display_from_socket() {
  local socket
  for socket in /tmp/.X11-unix/X*; do
    if [[ -S "$socket" ]]; then
      printf ':%s\n' "${socket##*/X}"
      return 0
    fi
  done
  return 1
}

export_from_process_environ() {
  local pid="$1"
  local key="$2"
  local line

  if [[ ! -r "/proc/${pid}/environ" ]]; then
    return 1
  fi

  line="$(tr '\0' '\n' < "/proc/${pid}/environ" | sed -n "s/^${key}=//p" | head -n 1)"
  if [[ -z "$line" ]]; then
    return 1
  fi

  declare -gx "$key=$line"
}

set_default_xdg_runtime_dir() {
  local runtime_dir
  runtime_dir="/run/user/$(id -u)"
  if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "$runtime_dir" ]]; then
    XDG_RUNTIME_DIR="$runtime_dir"
    export XDG_RUNTIME_DIR
  fi
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "${XDG_RUNTIME_DIR:-}/bus" ]]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
    export DBUS_SESSION_BUS_ADDRESS
  fi
}

export_env_line_if_missing() {
  local line="$1"
  local key="${line%%=*}"
  local value="${line#*=}"

  if [[ "$line" != *=* || -z "$key" || -n "${!key:-}" || -z "$value" ]]; then
    return 1
  fi

  declare -gx "$key=$value"
}

adopt_systemd_user_env() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  set_default_xdg_runtime_dir

  local environment
  environment="$(systemctl --user show-environment 2>/dev/null || true)"
  if [[ -z "$environment" ]]; then
    return 1
  fi

  local line
  local adopted=0
  while IFS= read -r line; do
    case "$line" in
      DISPLAY=*|XAUTHORITY=*|XDG_RUNTIME_DIR=*|WAYLAND_DISPLAY=*|DBUS_SESSION_BUS_ADDRESS=*)
        export_env_line_if_missing "$line" && adopted=1
        ;;
    esac
  done <<< "$environment"

  [[ "$adopted" == 1 ]]
}

adopt_process_env_for_display() {
  local wanted_display="${DISPLAY:-}"
  if [[ -z "$wanted_display" ]]; then
    return 1
  fi

  local current_uid
  current_uid="$(id -u)"

  local environ
  local pid
  local proc_uid
  local proc_env
  local key
  local value
  local adopted=0
  for environ in /proc/[0-9]*/environ; do
    [[ -r "$environ" ]] || continue
    pid="${environ#/proc/}"
    pid="${pid%%/*}"
    proc_uid="$(stat -c %u "/proc/$pid" 2>/dev/null || true)"
    [[ "$proc_uid" == "$current_uid" ]] || continue

    proc_env="$(tr '\0' '\n' < "$environ" 2>/dev/null || true)"
    if ! grep -Fxq "DISPLAY=$wanted_display" <<< "$proc_env"; then
      continue
    fi

    for key in XAUTHORITY XDG_RUNTIME_DIR WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS; do
      if [[ -n "${!key:-}" ]]; then
        continue
      fi
      value="$(sed -n "s/^${key}=//p" <<< "$proc_env" | head -n 1)"
      if [[ -n "$value" ]]; then
        declare -gx "$key=$value"
        adopted=1
      fi
    done

    if [[ -n "${XAUTHORITY:-}" && -r "$XAUTHORITY" ]]; then
      return 0
    fi
  done

  [[ "$adopted" == 1 ]]
}

adopt_graphical_session_env() {
  if ! command -v loginctl >/dev/null 2>&1; then
    return 1
  fi

  local session_id="${SAFE_LLM_HOST_GRAPHICAL_SESSION:-}"
  if [[ -z "$session_id" ]]; then
    session_id="$(loginctl show-user "$(id -u)" -p Display --value 2>/dev/null || true)"
  fi
  if [[ -z "$session_id" ]]; then
    session_id="$(
      loginctl list-sessions --no-legend 2>/dev/null \
        | awk -v uid="$(id -u)" '$2 == uid && $4 ~ /^seat/ { print $1; exit }'
    )"
  fi
  if [[ -z "$session_id" ]]; then
    return 1
  fi

  local remote
  remote="$(loginctl show-session "$session_id" -p Remote --value 2>/dev/null || true)"
  if [[ "$remote" == "yes" ]]; then
    return 1
  fi

  local display
  display="$(loginctl show-session "$session_id" -p Display --value 2>/dev/null || true)"
  if [[ -n "$display" && -z "${DISPLAY:-}" ]]; then
    DISPLAY="$display"
    export DISPLAY
  fi

  local leader
  leader="$(loginctl show-session "$session_id" -p Leader --value 2>/dev/null || true)"
  if [[ -n "$leader" && -r "/proc/${leader}/environ" ]]; then
    if [[ -z "${DISPLAY:-}" ]]; then
      export_from_process_environ "$leader" DISPLAY || true
    fi
    if [[ -z "${XAUTHORITY:-}" ]]; then
      export_from_process_environ "$leader" XAUTHORITY || true
    fi
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
      export_from_process_environ "$leader" XDG_RUNTIME_DIR || true
    fi
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
      export_from_process_environ "$leader" WAYLAND_DISPLAY || true
    fi
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
      export_from_process_environ "$leader" DBUS_SESSION_BUS_ADDRESS || true
    fi
  fi

  [[ -n "${DISPLAY:-}" ]]
}

infer_xauthority_from_x_server() {
  local wanted_display="${DISPLAY:-}"
  if [[ -z "$wanted_display" ]]; then
    return 1
  fi

  local cmdline
  local args
  local i
  local has_display
  local auth_file
  for cmdline in /proc/[0-9]*/cmdline; do
    [[ -r "$cmdline" ]] || continue
    mapfile -d '' -t args < "$cmdline" || continue
    [[ "${#args[@]}" -gt 0 ]] || continue
    case "${args[0]}" in
      *Xorg*|*Xwayland*|*/X)
        ;;
      *)
        continue
        ;;
    esac

    has_display=0
    auth_file=""
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "$wanted_display" ]]; then
        has_display=1
      elif [[ "${args[$i]}" == "-auth" ]] && ((i + 1 < ${#args[@]})); then
        auth_file="${args[$((i + 1))]}"
      fi
    done

    if [[ "$has_display" == 1 && -n "$auth_file" && -r "$auth_file" ]]; then
      printf '%s\n' "$auth_file"
      return 0
    fi
  done

  return 1
}

infer_xauthority_from_files() {
  set_default_xdg_runtime_dir

  local candidate
  local candidates=()
  if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    candidates+=(
      "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.*
      "$XDG_RUNTIME_DIR"/*/Xauthority
      "$XDG_RUNTIME_DIR"/*Xauthority*
      "$XDG_RUNTIME_DIR"/.Xauthority
    )
  fi
  candidates+=("$HOME/.Xauthority")

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" && -r "$candidate" && -s "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

setup_host_xauthority_for_chrome() {
  if [[ -n "${SAFE_LLM_HOST_XAUTHORITY:-}" ]]; then
    XAUTHORITY="$SAFE_LLM_HOST_XAUTHORITY"
    export XAUTHORITY
  fi

  if [[ -n "${XAUTHORITY:-}" && -r "$XAUTHORITY" ]]; then
    return 0
  fi

  local auth_file
  auth_file="$(infer_xauthority_from_x_server || infer_xauthority_from_files || true)"
  if [[ -n "$auth_file" ]]; then
    XAUTHORITY="$auth_file"
    export XAUTHORITY
  fi
}

setup_host_display_for_chrome() {
  if [[ "$HOST_OS" != "Linux" ]]; then
    return 0
  fi

  if [[ "${SAFE_LLM_HOST_DISPLAY:-}" == "none" || "${SAFE_LLM_HOST_DISPLAY:-}" == "0" ]]; then
    return 0
  fi

  if [[ -n "${SAFE_LLM_HOST_DISPLAY:-}" ]]; then
    DISPLAY="$SAFE_LLM_HOST_DISPLAY"
    export DISPLAY
  elif is_ssh_session; then
    set_default_xdg_runtime_dir
    adopt_systemd_user_env || true
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
      adopt_graphical_session_env || DISPLAY="$(infer_x_display_from_socket || true)"
    fi
    if [[ -n "${DISPLAY:-}" ]]; then
      export DISPLAY
    fi
  fi

  if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    adopt_systemd_user_env || true
    if [[ -n "${DISPLAY:-}" ]]; then
      adopt_process_env_for_display || true
      setup_host_xauthority_for_chrome
    fi
  fi

  if [[ -n "${DISPLAY:-}" ]] && is_ssh_session; then
    if [[ -n "${XAUTHORITY:-}" ]]; then
      echo "Using host graphical display ${DISPLAY} for Chrome launched from SSH with XAUTHORITY=${XAUTHORITY}." >&2
    else
      echo "Using host graphical display ${DISPLAY} for Chrome launched from SSH." >&2
    fi
  elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && is_ssh_session; then
    echo "Using host Wayland display ${WAYLAND_DISPLAY} for Chrome launched from SSH." >&2
  fi
}

# Launch Chrome with remote debugging on $CHROME_DEVTOOLS_PORT. A dedicated
# --user-data-dir is required because Chrome forwards command-line flags to any
# already-running instance and silently ignores --remote-debugging-port when it
# does; a separate profile dir forces a fresh process that opens the debug port.
start_chrome() {
  local profile_dir="${CHROME_DEBUG_PROFILE_DIR:-${TMPDIR:-/tmp}/chrome-devtools-profile-${CHROME_DEVTOOLS_PORT}}"
  mkdir -p "$profile_dir"
  if [[ -z "${CHROME_START_LOG:-}" ]]; then
    CHROME_START_LOG="$(mktemp "${TMPDIR:-/tmp}/safe-llm-chrome.XXXXXX.log")"
    register_cleanup_file "$CHROME_START_LOG"
  fi

  if [[ "$HOST_OS" == "Darwin" ]]; then
    local chrome_bin="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if [[ ! -x "$chrome_bin" ]]; then
      echo "Could not find Google Chrome at: $chrome_bin" >&2
      return 1
    fi
    "$chrome_bin" \
      --remote-debugging-port="$CHROME_DEVTOOLS_PORT" \
      --user-data-dir="$profile_dir" \
      >"$CHROME_START_LOG" 2>&1 &
    disown || true
  else
    local chrome_bin
    local chrome_display_args=()
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
    setup_host_display_for_chrome
    if [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" && -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]; then
      chrome_display_args+=(--ozone-platform=wayland)
    fi
    "$chrome_bin" \
      "${chrome_display_args[@]}" \
      --remote-debugging-port="$CHROME_DEVTOOLS_PORT" \
      --user-data-dir="$profile_dir" \
      >"$CHROME_START_LOG" 2>&1 &
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
      if [[ -n "${CHROME_START_LOG:-}" && -s "$CHROME_START_LOG" ]]; then
        echo "Chrome startup log:" >&2
        tail -n 20 "$CHROME_START_LOG" >&2
      fi
      exit 1
    fi
  fi
}
