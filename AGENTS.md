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
