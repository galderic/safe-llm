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
- Registers the Plane MCP server when explicit Plane credentials are present,
  with a constrained default tool surface for predictable agent startup.
- Registers a scoped `devops` subagent (CI/CD, infra, Docker/K8s,
  observability, release engineering) defined in `agents/devops.md`.

## Layout

- `claude/` — `Dockerfile` + `run.sh` for the Claude Code sandbox
  (`claude-sandbox` image, Node 22 + Python + JDK 17 + Maven + `gh`).
  Installs Claude via the official `claude.ai/install.sh` script, configures
  the Chrome DevTools and Plane MCP servers, and overlays the devops subagent
  into `~/.claude/agents/`.
- `codex/` — `Dockerfile` + `run.sh` for the Codex sandbox
  (`codex-sandbox` image, Node 22 + Python + ripgrep + `socat`). Installs
  `@openai/codex` globally, rewrites `~/.codex/config.toml` to point the
  `chrome-devtools` MCP at the host-gateway proxy, configures the Plane MCP
  server, and appends an `[agents.devops]` block for the devops subagent.
- `lib/sandbox.sh` — shared launcher helpers for image rebuild checks,
  GitHub HTTPS auth forwarding, SSH agent / known_hosts forwarding, macOS
  passwd synthesis, Chrome DevTools proxying, Chrome startup, and portable
  shell utilities.
- `agents/devops.md` — system prompt for the devops subagent, mounted or
  staged into the container by the launchers.
- `scripts/plane-mcp-stdio-wrapper.py` — wrapper around the official
  `plane-mcp-server` stdio entrypoint that limits which Plane MCP tool groups
  are registered.

## Usage

From any project directory:

```sh
/path/to/safe-llm/claude/run.sh    # launch Claude Code in a sandbox
/path/to/safe-llm/codex/run.sh     # launch Codex in a sandbox
```

Both scripts rebuild their image automatically when the `Dockerfile` is
newer than the cached image, then start the agent with the current
directory mounted as the workspace.

To force a fresh image rebuild before launch, pass `--rebuild` as the first
launcher argument or set `SAFE_LLM_REBUILD=1`:

```sh
/path/to/safe-llm/claude/run.sh --rebuild
/path/to/safe-llm/codex/run.sh --rebuild

SAFE_LLM_REBUILD=1 /path/to/safe-llm/claude/run.sh
SAFE_LLM_REBUILD=1 /path/to/safe-llm/codex/run.sh
```

### Requirements

- Docker.
- Chrome running with `--remote-debugging-port=9222` (or override via
  `CHROME_DEVTOOLS_PORT` / `DEVTOOLS_PROXY_PORT`) if you want the
  `chrome-devtools` MCP to work.
- Plane MCP credentials in the environment if you want the `plane` MCP to be
  registered: `PLANE_API_KEY` and `PLANE_WORKSPACE_SLUG`. `PLANE_BASE_URL` is
  optional and defaults to Plane Cloud when unset. `PLANE_MCP_TOOL_GROUPS`
  optionally expands the default Plane MCP tool surface.
- A host-side login for the agent you're launching (`~/.claude` or
  `~/.codex`).

### Local agent environment

Docker is not installed in this agent workspace, and it should not be
installed here. Agents should not try to build images or run Docker-based
launcher validation locally; use static checks where possible and surface that
Docker validation needs to be run in an environment where Docker is already
available.

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

Plane MCP is integrated through the official server and a local stdio wrapper:

- Both launchers register the official Python-based `plane-mcp-server` through
  `uvx --from plane-mcp-server python /tmp/plane-mcp-stdio-wrapper.py stdio`.
  The wrapper imports the upstream `plane_mcp` package, replaces its tool
  registration hook, then calls the official stdio entrypoint. It does not
  implement Plane API behavior itself.
- The Plane MCP server is registered only when `PLANE_API_KEY` and
  `PLANE_WORKSPACE_SLUG` are present on the host, because the stdio server exits
  during initialization when either is missing.
- The launchers run Plane through `scripts/plane-mcp-stdio-wrapper.py`, which
  defaults to `PLANE_MCP_TOOL_GROUPS=work_items,work_item_comments,states`.
  With that default, agents can manage work items, add comments to work items,
  and inspect states so they can move work items from one state to another
  through the work-item update tools.
- Override `PLANE_MCP_TOOL_GROUPS` with a comma-separated list when a broader
  Plane surface is needed, for example
  `PLANE_MCP_TOOL_GROUPS=work_items,work_item_comments,states,labels`. Supported groups
  are `cycles`, `epics`, `initiatives`, `intake`, `labels`, `milestones`,
  `modules`, `pages`, `projects`, `states`, `users`,
  `work_item_activities`, `work_item_comments`, `work_item_links`,
  `work_item_properties`, `work_item_relations`, `work_item_types`,
  `work_items`, `work_logs`, and `workspaces`.
- Running the upstream command directly as `uvx plane-mcp-server stdio` would
  expose the full Plane MCP tool surface, but the larger `tools/list` response
  was the reason the wrapper was added. Keep the wrapper unless Codex startup
  has been revalidated against the full upstream tool set.
- `PLANE_BASE_URL`, `PLANE_API_KEY`, and `PLANE_WORKSPACE_SLUG` are passed into
  the container. Codex also lists these names in `mcp_servers.plane.env_vars`
  so the MCP subprocess inherits them without writing secret values into CLI
  arguments or config files. `UV_CACHE_DIR` and `UV_TOOL_DIR` are redirected to
  `/tmp` so `uvx` does not need to write into the image home when the container
  runs as the host uid.
- The launchers do not discover Plane credentials or write Plane tokens into
  images or persistent config files.

Tool config and login state are mounted narrowly:

- Claude mounts host `~/.claude` at `/home/claude/.claude`, mounts a temporary
  rewritten `.claude.json` at `/home/claude/.claude.json`, and overlays
  `agents/devops.md` into `/home/claude/.claude/agents/devops.md` read-only.
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
- Codex stages `agents/devops.md` into `$CODEX_HOME/agents/devops.toml`
  because Docker Desktop cannot reliably nest-mount a file inside an already
  bind-mounted `$CODEX_HOME`; the staged file is removed on exit.

## Terminal rendering

Both launchers pass explicit terminal metadata into the container so rich TUI
output renders consistently:

- `TERM` defaults to the host value, except empty, `dumb`, and `xterm-ghostty`
  are normalized to `xterm-256color` because that terminfo entry is available in
  the Debian-based images.
- `COLORTERM` defaults to `truecolor`.
- `LANG` and `LC_ALL` default to `C.UTF-8` so Unicode table and box-drawing
  characters are not downgraded to ASCII.

Set `SAFE_LLM_TERM`, `SAFE_LLM_LANG`, or `SAFE_LLM_LC_ALL` before launching if a
project needs different container-side values.
