# Plugins

## openviking-memory

Source: the official OpenViking plugins, pinned to release **v0.5.5** — Claude Code installs
[`examples/claude-code-memory-plugin`](https://github.com/volcengine/OpenViking/tree/v0.5.5/examples/claude-code-memory-plugin)
(plugin 0.7.22), Codex installs
[`examples/codex-memory-plugin`](https://github.com/volcengine/OpenViking/tree/v0.5.5/examples/codex-memory-plugin)
(plugin 0.11.21). Both are named `openviking-memory`, so `ov-wiki`'s dependency resolves on either host.

Gives the agent a memory that outlives the session, kept on your OpenViking server.

- **Session start** — injects your profile and an index of stored preferences and entities.
- **Every prompt** — recalls memories relevant to it and adds them to the turn.
- **Every turn end** — appends the new messages to a server-side session and commits it once the
  server reports more pending tokens than `commitTokenThreshold` (default 20000).
- **Session end and before compaction** — commits the session, and the server extracts durable
  memories from it. Claude Code also captures subagents.
- **Tools** — a local MCP proxy forwards the server's own MCP tools (`search`, `find`, `read`, `list`,
  `glob`, `grep`, `write`, `edit`, `remember`, …); the exact set comes from your server version.

Needs Node.js 18 or newer on the `PATH` of the environment that launches the host: the hooks and the
proxy run the bare `node` command.

Skills: `openviking-memory`, `ov-experience-memory`, `ov-memory-doctor`, `openviking-skills` and
`openviking-rule-search`. Full reference:
[Claude Code](https://github.com/volcengine/OpenViking/blob/v0.5.5/docs/en/agent-integrations/02-claude-code.md),
[Codex](https://github.com/volcengine/OpenViking/blob/v0.5.5/docs/en/agent-integrations/04-codex.md).

Memories are filed under a workspace peer derived from the repository's git `origin` (falling back to
the repository root). Outside a git repository memories go to your user-level space. Memories filed under
a peer derived from the working directory are still recalled; to keep writing under such peers, set
`"peerSource": "cwd"` under `plugin` in `~/.openviking/ovcli.conf`.

To update to a newer OpenViking release, change `ref` in both marketplace files to the new tag.

## ov-wiki

Repository: [purisev/openviking-wiki](https://github.com/purisev/openviking-wiki). The plugin was called
`openviking-wiki` until 0.3.0; the repository keeps that name.

Maintains a Markdown wiki that the agent writes and keeps consistent, stored in OpenViking: source
summaries, entity and concept pages, an index and a log. The wiki is private to your user by default
(`viking://user/<you>/resources/wiki`); a shared one (`viking://resources/wiki`) is used only when you
say so.

| Command | Does |
| --- | --- |
| `/wiki-init` | Creates the wiki's schema, index and log. |
| `/wiki-ingest` | Reads a source and files it into the wiki. |
| `/wiki-query` | Answers from the wiki, with citations. |
| `/wiki-lint` | Checks structure, links and index coverage. |
| `/wiki-recover` | Finishes or rolls forward an interrupted multi-page update. |

It registers no tools of its own and uses the OpenViking tools of `openviking-memory`. Claude Code
installs that plugin automatically as a declared dependency; under Codex install it yourself.

Two offline helpers, `wiki_validate.py` and `wiki_plan.py`, are optional. They need Python 3 with
PyYAML; `uv run` resolves that from the scripts' headers. Without them the agent runs the same checks
through the tools.

## humanizer

Source: [blader/humanizer](https://github.com/blader/humanizer), release **v4.0.0**, by Siqi Chen. MIT.
Claude Code installs it from that repository; Codex installs a copy of the same commit from
[purisev/agent-skills](https://github.com/purisev/agent-skills/tree/main/humanizer), because Codex
does not find a skill kept at the root of a repository.

One skill, `humanizer`: rewrites text so it reads like its writer, removing AI writing patterns such
as forced triads, staged openers, inflated claims and stock AI words, without changing what it says.

If you installed it earlier from its author's marketplace, remove that copy, or the skill appears
twice: `claude plugin uninstall humanizer@humanizer` and `claude plugin marketplace remove humanizer`.

## ponytail

Source: [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail), release **v5.3.3**, by
Dietrich Gebert. MIT. Both hosts install it from that repository.

"Lazy senior dev mode": steers the agent towards the smallest change that fully solves the task —
YAGNI, the standard library first, no abstractions nobody asked for.

- **Hooks** at session start, at subagent start and on every prompt turn the mode on in every session
  and every subagent, at level `full`. `PONYTAIL_DEFAULT_MODE=off` in the host's environment, or
  `defaultMode` in `~/.config/ponytail/config.json`, changes the default.
- **Skills**: `ponytail`, `ponytail-review`, `ponytail-audit`, `ponytail-debt`, `ponytail-gain`,
  `ponytail-help`.
- **Task board** (Claude Code): after every turn it appends a row to
  `~/.config/ponytail/band/<project>.csv`. A webhook can receive the same row; it is off until you set
  its URL in the plugin's options. Nothing leaves the machine without it.

Needs `node` on `PATH` for its hooks; without it the skills still work. Codex asks to approve its hooks
once (`/hooks`).

## infra

Source: [purisev/agent-skills](https://github.com/purisev/agent-skills/tree/main/infra).

Skills for infrastructure command-line tools. They work through the tools' own CLIs, which must be
installed, and prefer checks and previews to changes.

| Skill | Covers |
| --- | --- |
| `ansible` | Inventories, playbooks, roles, check and diff runs, collections, Vault. |
| `helm` | Charts and releases: render, lint, package, install, upgrade, rollback, OCI registries. |
| `metricsql` | VictoriaMetrics MetricsQL queries for dashboards, alerts and recording rules. |
| `terraform` | Authoring, `fmt`, `validate`, speculative `plan`, read-only state. Never `apply`, `destroy` or state changes. |
| `terramate` | Terramate templating and code generation: `generate_hcl`, globals, `tm_*` functions. |

## playwright

Source: [Clawic's Playwright skill](https://clawic.com/skills/playwright) by Ivan G. Davila, version
**1.0.4**, from [clawic/skills](https://github.com/clawic/skills/tree/main/skills/playwright) pinned to a
commit. MIT. Claude Code installs it from that repository, where the skill is listed as
`playwright:Playwright--Automation---MCP---Scraper-`; Codex installs a copy of the same commit from
[purisev/agent-skills](https://github.com/purisev/agent-skills/tree/main/playwright), where it is
`playwright:playwright`.

Writes and repairs Playwright tests, diagnoses flaky and CI-only failures, drives a live browser
through Playwright MCP and extracts data from JS-rendered pages. Needs Node.js and `npx`; Playwright
and `@playwright/mcp` are installed on first use. The skill keeps its own preferences in
`~/Clawic/data/playwright/`.

## Third-party plugins

`humanizer`, `ponytail` and `playwright` come from repositories purisev does not maintain. Each is
pinned to one commit in both catalogs, so an update reaches you only when the pin here changes.

## Platforms

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Installer | tested, including the Node.js download | same script; run in CI | `install.ps1`; run in CI |
| Plugins under Claude Code | tested | expected to work | hooks need `sh`, which Git for Windows provides |
| Plugins under Codex | install, hooks and MCP wiring tested | expected to work | not tested |

"Expected to work" means nothing platform-specific is known to be in the way, and nobody has checked.
