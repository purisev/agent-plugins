# purisev agent plugins

Plugins for [Claude Code](https://claude.com/claude-code) and [Codex](https://developers.openai.com/codex),
published as one marketplace named `purisev`. An installed plugin has the same id under both hosts:
`<plugin>@purisev`.

| Plugin | What it does |
| --- | --- |
| [`openviking-memory`](plugins.md#openviking-memory) | Long-term semantic memory backed by an [OpenViking](https://github.com/volcengine/OpenViking) server, plus OpenViking's tools for the agent. |
| [`openviking-wiki`](plugins.md#openviking-wiki) | An agent-authored Markdown wiki stored in OpenViking. |

## Install

Linux and macOS:

```sh
curl -fsSL https://ai-plugins.purisev.com/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://ai-plugins.purisev.com/install.ps1 | iex
```

The installer:

1. checks for `git` and for Node.js 18 or newer, which `openviking-memory` runs on. When Node.js is
   missing it offers the official build, checksum-verified, under your home directory — no root or
   administrator rights, and nothing is installed without a yes;
2. finds Claude Code and Codex on `PATH`, adds the `purisev` marketplace to each, and installs or
   updates the plugins;
3. removes, with your consent, an earlier install made from a plugin's own former marketplace, which
   would otherwise run every hook twice;
4. offers to create `~/.openviking/ovcli.conf` when there is none, and leaves an existing one alone.

It is safe to run again: a second run updates what is there.

### Look before you run

Piping a script into a shell means trusting the address it came from. To read it first:

```sh
curl -fsSL https://ai-plugins.purisev.com/install.sh -o install.sh
less install.sh
sh install.sh --dry-run    # prints every command, changes nothing
sh install.sh
```

```powershell
irm https://ai-plugins.purisev.com/install.ps1 -OutFile install.ps1
.\install.ps1 -DryRun
.\install.ps1
```

### Options

| `install.sh` | `install.ps1` | Meaning |
| --- | --- | --- |
| `--host claude` | `-AgentHost claude` | Install into this host only (`claude` or `codex`). Repeatable. |
| `--plugin openviking-memory` | `-Plugin openviking-memory` | Install this plugin only. Repeatable. |
| `--no-config` | `-NoConfig` | Do not offer to create the connection file. |
| `-y`, `--yes` | `-Yes` | Answer yes to every question. Nothing is asked, so the connection file is not created. |
| `--dry-run` | `-DryRun` | Print what would be done and change nothing. |

Options after a pipe: `curl -fsSL https://ai-plugins.purisev.com/install.sh | sh -s -- --dry-run`, and
`& ([scriptblock]::Create((irm https://ai-plugins.purisev.com/install.ps1))) -DryRun`.

## Install by hand

Claude Code:

```
/plugin marketplace add purisev/agent-plugins
/plugin install openviking-wiki@purisev
```

`openviking-wiki` declares `openviking-memory` as a dependency, so Claude Code installs both.

Codex:

```sh
codex plugin marketplace add purisev/agent-plugins
codex plugin add openviking-memory@purisev
codex plugin add openviking-wiki@purisev
```

Then start `codex`, run `/hooks`, and approve the hooks `openviking-memory` brings. Codex asks once,
and again whenever a plugin update changes them.

## After installing

Restart the host, then [connect it to your OpenViking server](connection.md). To check the result, ask
the agent to run the `ov-memory-doctor` skill; [Troubleshooting](troubleshooting.md) explains its report.
