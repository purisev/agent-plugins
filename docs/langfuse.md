# Send traces to Langfuse

`langfuse-observability` sends every Claude Code and Codex session to a [Langfuse](https://langfuse.com)
server. Each turn becomes a trace with the prompt, the model calls, every tool call with its input and
output, and token usage. Langfuse Cloud and a self-hosted Langfuse v3 or newer both work.

The installer adds it only when asked to, because everything the agent sees reaches the server:
prompts, command output, the contents of the files it reads, and any secrets among them. The Claude
Code plugin cuts each field to 20 000 characters; the Codex plugin sends everything. Neither masks
anything.

## Install

Create a project in Langfuse and an API key pair for it (project settings, API Keys). Both hosts send to
that project.

```sh
curl -fsSL https://ai-plugins.purisev.com/install.sh | sh -s -- --langfuse
```

```powershell
& ([scriptblock]::Create((irm https://ai-plugins.purisev.com/install.ps1))) -Langfuse
```

The installer asks for the server URL and both keys, checks them against the server, and saves them for
each host. It saves nothing the server refuses. Without a terminal it reads them from
`LANGFUSE_BASE_URL`, `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY`:

```sh
export LANGFUSE_BASE_URL=https://langfuse.example.com LANGFUSE_PUBLIC_KEY=pk-lf-... LANGFUSE_SECRET_KEY=sk-lf-...
curl -fsSL https://ai-plugins.purisev.com/install.sh | sh -s -- --langfuse --yes
```

Keys a host already has are left alone. Once the plugin is installed, every later run of the installer
updates it, with or without `--langfuse`.

| | Claude Code | Codex |
| --- | --- | --- |
| Plugin | `langfuse-observability@purisev`: [Langfuse's Claude Code plugin](https://github.com/langfuse/Claude-Observability-Plugin) v1.2.2 | `tracing@purisev`: [Langfuse's Codex plugin](https://github.com/langfuse/codex-observability-plugin) 0.4.3, from npm, which Codex fetches with `npm pack`; without npm the installer skips it |
| Keys | the plugin's options; the secret key in the system keychain, or in `~/.claude/.credentials.json` where there is none | `~/.codex/langfuse.json`, readable by you only |
| Hook | `Stop` and `SessionEnd`, run with `uv`, which the installer offers when it is missing | `Stop`, run with Node.js 22 or newer, which the installer offers in the same way |

Codex installs a plugin only under the name its manifest gives, so there it is `tracing`. Codex asks to
approve its hook once (`/hooks`), and again after an update that changes it.

## Settings

Claude Code: `/plugin configure langfuse-observability@purisev` lists the options, among them a user ID
for every trace, the field length limit, image capture, and a debug log in
`~/.claude/state/langfuse_hook.log`.

Codex: `~/.codex/langfuse.json`, a project's own `.codex/langfuse.json`, or `LANGFUSE_*` variables in
the environment, which take precedence. The keys are listed in
[Langfuse's Codex documentation](https://langfuse.com/integrations/developer-tools/codex).

Both plugins upload images to Langfuse. A self-hosted server stores them only with a media bucket
configured (`LANGFUSE_S3_MEDIA_UPLOAD_BUCKET`); without one, turn off image capture in the Claude Code
options.

## Stop sending

- Claude Code: `claude plugin disable langfuse-observability@purisev`, or `uninstall` to remove it.
- Codex: `"enabled": false` in `~/.codex/langfuse.json`, or `codex plugin remove tracing@purisev`.

## Check it

Finish one turn in each host and open Tracing in the Langfuse project. Nothing there after a turn: in
Claude Code, set the debug option and read its log; in Codex, check that the hook is approved in
`/hooks` and that `node --version` reports 22 or newer.
