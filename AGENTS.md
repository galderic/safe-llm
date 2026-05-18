# safe-llm

Containerized sandboxes for running coding agents (Claude Code and OpenAI
Codex) against a local workspace without giving them direct access to the
host. The goal is to let an agent run with permission prompts disabled
(`--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`)
while keeping the blast radius bounded by a Docker container.

## Goal

Provide a uniform, low-friction way to launch either agent in a disposable
sandbox that:

- Mounts only the current working directory as the agent's workspace.
- Reuses the host's existing agent credentials and config (`~/.claude`,
  `~/.codex`) read-only or via overlay, so login state carries over.
- Forwards GitHub auth (`GH_TOKEN` / `GITHUB_TOKEN`) and SSH agent into
  the container so `git` and `gh` work without baking secrets into images.
- Bridges the host's Chrome DevTools endpoint into the container via a
  `socat` proxy so the `chrome-devtools` MCP server can drive the host
  browser from inside the sandbox.
- Registers a scoped `devops` subagent (CI/CD, infra, Docker/K8s,
  observability, release engineering) defined in `<tool>/agents/devops.md`.

## Layout

- `claude/` — `Dockerfile` + `run.sh` for the Claude Code sandbox
  (`claude-sandbox` image, Node 22 + Python + JDK 17 + Maven + `gh`).
  Installs Claude via the official `claude.ai/install.sh` script and
  overlays the devops subagent into `~/.claude/agents/`.
- `codex/` — `Dockerfile` + `run.sh` for the Codex sandbox
  (`codex-sandbox` image, Node 22 + ripgrep + `socat`). Installs
  `@openai/codex` globally, rewrites `~/.codex/config.toml` to point the
  `chrome-devtools` MCP at the host-gateway proxy, and appends an
  `[[agents]]` block for the devops subagent.
- `<tool>/agents/devops.md` — system prompt for the devops subagent,
  mounted read-only into the container.

## Usage

From any project directory:

```sh
/path/to/safe-llm/claude/run.sh    # launch Claude Code in a sandbox
/path/to/safe-llm/codex/run.sh     # launch Codex in a sandbox
```

Both scripts rebuild their image automatically when the `Dockerfile` is
newer than the cached image, then start the agent with the current
directory mounted as the workspace.

### Requirements

- Docker.
- Chrome running with `--remote-debugging-port=9222` (or override via
  `CHROME_DEVTOOLS_PORT` / `DEVTOOLS_PROXY_PORT`) if you want the
  `chrome-devtools` MCP to work.
- A host-side login for the agent you're launching (`~/.claude` or
  `~/.codex`).

## Host/container identity and secret mapping

This file is for Claude and Codex agents working inside this repository.
When changing the launch scripts, preserve the sandbox boundary: host
credentials may be forwarded through narrow mounts or environment variables,
but the container should not receive a broad copy of the host home directory.

Both launchers run the container process as the host uid/gid:

- `--user "$(id -u):$(id -g)"` is used so files written in the mounted
  workspace remain owned by the invoking host user.
- `HOME` is set to the tool-specific container home (`/home/claude` for
  Claude, `/home/node` by default for Codex) even though the numeric uid/gid
  are the host user's ids.
- On macOS, the host uid (commonly `501`) usually has no entry in the Linux
  image's `/etc/passwd`. OpenSSH fails early with `No user exists for uid ...`
  in that state, so each script synthesizes a temporary passwd file containing
  the image's normal entries plus a `hostuser` entry for the host uid/gid and
  bind-mounts it over `/etc/passwd`.
- On Linux, no synthesized passwd mount is currently used because the mapped
  uid normally works for the expected git/ssh paths.

SSH is forwarded by agent socket, not by copying private keys:

- On Linux, if `$SSH_AUTH_SOCK` points at a real socket, that socket is
  bind-mounted into the container as `/ssh-agent` and `SSH_AUTH_SOCK=/ssh-agent`
  is exported.
- On macOS Docker Desktop, the host launchd ssh-agent socket cannot be mounted
  directly. Docker Desktop exposes it through the special mount source
  `/run/host-services/ssh-auth.sock`, which is mounted as `/ssh-agent`.
- On macOS, Docker Desktop presents that synthetic socket as `root:root 0660`,
  so the launchers add `--group-add 0` to let the host-uid-mapped process open
  it.
- The user must have keys loaded into the host ssh-agent (`ssh-add -l`). The
  scripts do not mount `~/.ssh/id_*`, `~/.ssh/config`, or other private SSH
  material into the container.

Known hosts are forwarded separately from credentials:

- If `$HOME/.ssh/known_hosts` exists on the host, it is mounted read-only into
  the container home as `~/.ssh/known_hosts`.
- This lets `ssh`, `git fetch`, and `git push` verify remote host keys without
  an interactive prompt.
- The direct file mount also causes Docker to create the container-side
  `~/.ssh` directory during mount setup. That matters because the process runs
  as the host uid while the image home is owned by the image user (`claude` or
  `node`, uid `1000`), so the process may not be able to create `~/.ssh`
  itself.

GitHub HTTPS auth is forwarded without writing credentials into images:

- `GH_TOKEN` and `GITHUB_TOKEN` are passed through.
- A one-shot Git credential helper is injected through `GIT_CONFIG_COUNT` /
  `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0`; it answers only GitHub HTTPS
  credential lookups and reads the token from the environment.
- Claude also mounts the host `~/.gitconfig` read-only when present. Codex
  currently does not.

Tool config and login state are mounted narrowly:

- Claude mounts host `~/.claude` at `/home/claude/.claude`, mounts a temporary
  rewritten `.claude.json` at `/home/claude/.claude.json`, and overlays
  `claude/agents/devops.md` into `/home/claude/.claude/agents/devops.md`
  read-only.
- On macOS, Claude subscription credentials normally live in the login
  Keychain, which the container cannot read. If `~/.claude/.credentials.json`
  is absent, `claude/run.sh` extracts the `Claude Code-credentials` Keychain
  item into that path with `0600` permissions before launch, then removes it on
  exit.
- Codex uses `${CODEX_HOME:-$HOME/.codex}` as the host Codex directory and
  mounts it at the same path inside the container by default. `HOME` still
  points at `/home/node` unless `DEV_CONTAINER_HOME` overrides it.
- Codex temporarily edits `config.toml` to rewrite the `chrome-devtools` MCP
  URL and append the `devops` agent block, then restores the original file from
  a backup on exit.
- Codex stages `codex/agents/devops.md` into `$CODEX_HOME/agents/devops.md`
  because Docker Desktop cannot reliably nest-mount a file inside an already
  bind-mounted `$CODEX_HOME`; the staged file is removed on exit.
