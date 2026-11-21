# agent-plugins

The `purisev` plugin marketplace for Claude Code and Codex. Documentation: **<https://ai-plugins.purisev.com>**

```sh
curl -fsSL https://ai-plugins.purisev.com/install.sh | sh     # Linux, macOS
```

```powershell
irm https://ai-plugins.purisev.com/install.ps1 | iex          # Windows
```

Or by hand:

```
/plugin marketplace add purisev/agent-plugins                 # Claude Code
/plugin install ov-wiki@purisev

codex plugin marketplace add purisev/agent-plugins            # Codex
codex plugin add openviking-memory@purisev
```

## Plugins

| Plugin | What it does |
| --- | --- |
| [`openviking-memory`](docs/plugins.md#openviking-memory) | Long-term semantic memory backed by an [OpenViking](https://github.com/volcengine/OpenViking) server, plus OpenViking's tools for the agent. The official upstream plugin, pinned to OpenViking v0.5.5. |
| [`ov-wiki`](https://github.com/purisev/openviking-wiki) | An agent-authored Markdown wiki stored in OpenViking. Depends on `openviking-memory`. |
| [`humanizer`](docs/plugins.md#humanizer) | Rewrites AI-sounding text so it reads like the writer. Third-party, pinned to v4.0.0. |
| [`ponytail`](docs/plugins.md#ponytail) | Steers the agent towards the smallest change that solves the task. Third-party, pinned to v5.3.3. |
| [`infra`](https://github.com/purisev/agent-skills/tree/main/infra) | Skills for Ansible, Helm, Terraform (preflight only), Terramate and MetricsQL. |
| [`playwright`](docs/plugins.md#playwright) | Browser tests, automation and scraping with Playwright. Third-party, pinned to a commit. |
| [`langfuse-observability`](docs/langfuse.md) | Sends every session to a [Langfuse](https://langfuse.com) server as traces. Langfuse's own plugins, pinned to releases; the installer adds them only with `--langfuse`. |

## This repository

| Path | What |
| --- | --- |
| `.claude-plugin/marketplace.json` | The Claude Code catalog. |
| `.agents/plugins/marketplace.json` | The Codex catalog: the same plugins, with the source type Codex understands. |
| `docs/` | The site, built with mdBook. `docs/install.sh` and `docs/install.ps1` are the installers it serves. |
| `*.test.mjs` | `node --test`: catalog invariants and both installers against stand-in tools. |

Adding a plugin, and the checks to run: [docs/adding-a-plugin.md](docs/adding-a-plugin.md).
