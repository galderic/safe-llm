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
- Bridges selected host loopback service ports, including PostgreSQL's default
  `5432`, so sandboxed agents can reach host services at both `localhost` and
  `host.docker.internal`.
- Publishes common container dev-server ports on host loopback so the host
  Chrome instance can open apps started inside the sandbox.
- Registers the official GitHub MCP server when a GitHub token is present,
  with a constrained default toolset that includes GitHub Projects.

## Layout

- `Dockerfile` — shared multi-target sandbox image. The `both` target installs
  Claude Code, OpenAI Codex, shared CLI dependencies, Chrome DevTools MCP, and
  the GitHub MCP server, and the cross-agent review wrappers.
- `claude.sh` — launcher for the Claude Code sandbox. It starts the shared
  `safe-llm-sandbox` image with Claude as the primary agent, configures the
  Chrome DevTools and GitHub MCP servers, and also mounts Codex config so
  `safe-codex-review` is available inside the sandbox.
- `codex.sh` — launcher for the Codex sandbox. It starts the shared
  `safe-llm-sandbox` image with Codex as the primary agent, passes runtime
  config overrides for the Chrome DevTools and GitHub MCP servers, and also
  mounts Claude config so `safe-claude-review` is available inside the sandbox.
- `lib/sandbox.sh` — shared launcher helpers for image rebuild checks,
  GitHub HTTPS auth forwarding, SSH agent / known_hosts forwarding, macOS
  passwd synthesis, Chrome DevTools proxying, Chrome startup, and portable
  shell utilities.

## Usage

From any project directory:

```sh
/path/to/safe-llm/claude.sh    # launch Claude Code in a sandbox
/path/to/safe-llm/codex.sh     # launch Codex in a sandbox
```

Both scripts rebuild their image automatically when the root `Dockerfile` or
cross-agent wrapper scripts are newer than the cached image, then start the
agent with the current directory mounted as the workspace.

The launchers also inject this repository's `AGENTS.md` into the launched
agent's instruction context. This keeps the safe-llm sandbox rules active even
when `claude.sh` or `codex.sh` is started from another project whose own
`AGENTS.md` is discovered as the workspace instructions. Override the injected
file with `SAFE_LLM_INSTRUCTIONS_FILE=/path/to/file`, or disable this injection
with `SAFE_LLM_INCLUDE_INSTRUCTIONS=0`.

To force a fresh image rebuild before launch, pass `--rebuild` as the first
launcher argument or set `SAFE_LLM_REBUILD=1`:

```sh
/path/to/safe-llm/claude.sh --rebuild
/path/to/safe-llm/codex.sh --rebuild

SAFE_LLM_REBUILD=1 /path/to/safe-llm/claude.sh
SAFE_LLM_REBUILD=1 /path/to/safe-llm/codex.sh
```

### Requirements

- Docker.
- Chrome running with `--remote-debugging-port=9222` (or override via
  `CHROME_DEVTOOLS_PORT` / `DEVTOOLS_PROXY_PORT`) if you want the
  `chrome-devtools` MCP to work.
- Agent-scoped GitHub credentials in the environment. `claude.sh` requires
  `CLAUDE_GITHUB_TOKEN`; `codex.sh` requires `CODEX_GITHUB_TOKEN`.
- A host-side login for the agent you're launching (`~/.claude` or
  `~/.codex`).
- Optional Linear credentials can be scoped per agent with
  `CLAUDE_LINEAR_API_KEY` and `CODEX_LINEAR_API_KEY`. GitHub MCP tokens are
  scoped per agent with `CLAUDE_GITHUB_TOKEN` and `CODEX_GITHUB_TOKEN`. The
  launchers and cross-agent wrappers map the active agent's scoped value to the
  generic environment variable expected by the underlying tool
  (`LINEAR_API_KEY` or `GITHUB_PERSONAL_ACCESS_TOKEN`).

### Browser access to sandbox dev servers

Both launchers publish common app dev ports from the container to the host on
loopback only:

```sh
127.0.0.1:3001 -> container:3001
127.0.0.1:5173 -> container:5173
127.0.0.1:4173 -> container:4173
127.0.0.1:8000 -> container:8000
127.0.0.1:8080 -> container:8080
```

Override the list with `SAFE_LLM_FORWARD_PORTS`, using comma-separated port
numbers or explicit Docker publish specs. Set it to an empty string to disable
port publishing:

```sh
SAFE_LLM_FORWARD_PORTS=3002,9000 /path/to/safe-llm/codex.sh
SAFE_LLM_FORWARD_PORTS=127.0.0.1:9000:5173 /path/to/safe-llm/claude.sh
SAFE_LLM_FORWARD_PORTS= /path/to/safe-llm/codex.sh
```

`SAFE_LLM_FORWARD_HOST` controls the host bind address for bare port numbers
and defaults to `127.0.0.1`. Keep it loopback unless there is a specific reason
to expose a sandboxed dev server on the LAN.

For bare port numbers, the launchers skip any host port that is already in use
and continue starting the sandbox. Explicit Docker publish specs are passed
through unchanged.

The process inside the container must still listen on a non-loopback interface
such as `0.0.0.0`. For many Node projects that means running the dev server
with an explicit host flag, for example `npm run dev -- --host 0.0.0.0`.

### Container access to host services

Both launchers make selected host loopback service ports reachable from inside
the container through both `localhost` and `host.docker.internal`. The default
list is:

```sh
container 127.0.0.1:5432 -> host 127.0.0.1:5432
host.docker.internal:5432  -> host 127.0.0.1:5432
```

Override the list with `SAFE_LLM_HOST_PORTS`, using comma-separated port
numbers. Set it to an empty string to disable host service proxying:

```sh
SAFE_LLM_HOST_PORTS=5432,6379 /path/to/safe-llm/codex.sh
SAFE_LLM_HOST_PORTS= /path/to/safe-llm/claude.sh
```

This is separate from `SAFE_LLM_FORWARD_PORTS`: host service proxying lets code
inside the container call services running on the host, while port forwarding
lets the host browser call services running inside the container.

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

GitHub Projects MCP is integrated through the official GitHub MCP server:

- The image builds and installs `github-mcp-server` from the official
  `github/github-mcp-server` repository. Both launchers register it as
  `github-mcp-server stdio`.
- The GitHub MCP server is registered by the primary launchers only after the
  required scoped token is present: `CLAUDE_GITHUB_TOKEN` for Claude and
  `CODEX_GITHUB_TOKEN` for Codex.
- Each active agent maps its scoped token to `GITHUB_PERSONAL_ACCESS_TOKEN`
  before starting so the MCP subprocess inherits the right identity without
  writing secret values into CLI arguments or config files.
- The default GitHub MCP toolsets are
  `context,issues,pull_requests,projects`. Override `GITHUB_MCP_TOOLSETS` with
  a comma-separated list when a broader or narrower surface is needed. The
  launchers pass that value to the MCP server as `GITHUB_TOOLSETS`.
- Classic GitHub personal access tokens and fine-grained personal access
  tokens can both be used. Fine-grained tokens are preferred when practical
  because they can be scoped to specific organizations, repositories, and
  permissions. For organization Projects, ensure the token is authorized for
  the organization and has the relevant project, issue, and pull request
  permissions.
- The launchers do not discover GitHub credentials or write GitHub tokens into
  images or persistent config files.

Tool config and login state are mounted narrowly:

- Claude mounts host `~/.claude` at `/home/claude/.claude`, mounts a temporary
  rewritten `.claude.json` at `/home/claude/.claude.json`.
- On macOS, Claude subscription credentials normally live in the login
  Keychain, which the container cannot read. If `~/.claude/.credentials.json`
  is absent, `claude.sh` extracts the `Claude Code-credentials` Keychain
  item into that path with `0600` permissions before launch, then removes it on
  exit.
- Codex uses `${CODEX_HOME:-$HOME/.codex}` as the host Codex directory and
  mounts it at `/home/node/.codex` inside the container by default. `HOME`
  still points at `/home/node` unless `DEV_CONTAINER_HOME` overrides it.
- Codex passes config overrides to rewrite the `chrome-devtools` MCP URL and
  enable GitHub MCP when credentials are present.

## Cross-agent review

The shared `both` image includes two explicit review wrappers:

- `safe-claude-review` runs Claude as a secondary reviewer from a Codex
  session.
- `safe-codex-review` runs Codex as a secondary reviewer from a Claude
  session.

Cross-agent code review must go through GitHub pull requests. A primary agent
that wants review from the other agent should create or update a PR for the
change, invoke the reviewer with the PR number/URL and branch context, and
instruct it to publish findings as GitHub PR review comments or issue comments
on that PR. Do not ask the secondary agent for a direct chat-only review except
for local debugging of the review wrapper itself.

The wrappers switch only the agent home/config environment, not the Linux user.
The container process still runs as the host uid/gid so workspace files remain
owned by the invoking host user. Each wrapper sets `SAFE_LLM_SUBAGENT=1` for
traceability and injects a prompt-only recursion guard telling the secondary
reviewer not to invoke Claude, Codex, subagents, review bots, or other
agent-calling automation.

The wrappers also scope Linear identity for the subprocess:

- `safe-claude-review` maps `CLAUDE_LINEAR_API_KEY` to `LINEAR_API_KEY`.
- `safe-codex-review` maps `CODEX_LINEAR_API_KEY` to `LINEAR_API_KEY`.
- If the relevant agent-specific key is absent, `LINEAR_API_KEY` is unset for
  that subprocess.

The wrappers scope GitHub MCP identity the same way, with generic fallbacks for
existing setups:

- `safe-claude-review` maps `CLAUDE_GITHUB_TOKEN` to
  `GITHUB_PERSONAL_ACCESS_TOKEN` when set.
- `safe-codex-review` maps `CODEX_GITHUB_TOKEN` to
  `GITHUB_PERSONAL_ACCESS_TOKEN` when set.
- If the relevant agent-specific key is absent, the existing
  `GITHUB_PERSONAL_ACCESS_TOKEN` value is preserved. If that is absent,
  `GITHUB_TOKEN` and then `GH_TOKEN` are used as fallbacks.

## Cross-agent invocation outside review

The `safe-claude-review` / `safe-codex-review` wrappers exist only for the
PR-based review use case. They inject a recursion guard that forbids the
secondary agent from spawning subagents or calling other agents, so they are the
wrong tool for any cross-agent work that needs broader GitHub MCP automation or
any other agent-calling automation.

When one primary agent needs to drive the other for non-review work (e.g.
Claude asking Codex to act on a GitHub Project item, or vice versa), invoke the other
agent's CLI directly inside the sandbox and pass the per-agent secrets
explicitly. Do not go through the review wrappers.

- Map the scoped GitHub MCP token onto the generic name the target agent will
  use, e.g.
  `GITHUB_PERSONAL_ACCESS_TOKEN="$CODEX_GITHUB_TOKEN" codex exec ...` when
  Claude spawns Codex, or
  `GITHUB_PERSONAL_ACCESS_TOKEN="$CLAUDE_GITHUB_TOKEN" claude --print ...` when
  Codex spawns Claude. Apply the same pattern for `LINEAR_API_KEY` via
  `CODEX_LINEAR_API_KEY` / `CLAUDE_LINEAR_API_KEY` when Linear is in scope.
- `codex exec` invoked directly inside the sandbox does NOT inherit the
  `mcp_servers.*` overrides that `codex.sh` passes at launch. When the target
  agent needs GitHub MCP, re-pass the same `-c mcp_servers.github.*` overrides
  used by `codex.sh` (command `github-mcp-server`, args `["stdio"]`,
  `env_vars` listing `GITHUB_PERSONAL_ACCESS_TOKEN` and `GITHUB_TOOLSETS`,
  `startup_timeout_sec=30`). Pass `--dangerously-bypass-approvals-and-sandbox`
  on `codex exec` so MCP tool calls are not auto-cancelled.
- Prefer asking the target agent to call the MCP tools directly. The
  full-history subagent fork path has rejected MCP tool calls with
  `user cancelled MCP tool call` in this sandbox, while the same call from the
  parent `exec` invocation succeeds.

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
