# agent-plugins

The `purisev` plugin marketplace for coding agents. One repository serves Claude Code and Codex;
installed plugins have the same id, `<plugin>@purisev`, under both.

Claude Code:

```
/plugin marketplace add purisev/agent-plugins
/plugin install <plugin>@purisev
```

`/plugin marketplace update purisev` refreshes the catalog; `/plugin` lists what is installed, its
errors and its settings.

Codex:

```bash
codex plugin marketplace add purisev/agent-plugins
codex plugin add <plugin>@purisev
```

`codex plugin marketplace upgrade purisev` refreshes the catalog. Codex asks once, in `/hooks`, to
approve the lifecycle hooks a plugin brings. The Codex manifest of `openviking-wiki` declares no
dependency, so install `openviking-memory` yourself alongside it.

## Plugins

| Plugin | What it does | Needs |
| --- | --- | --- |
| [`openviking-memory`](https://github.com/purisev/openviking-memory) | Long-term semantic memory backed by an [OpenViking](https://github.com/volcengine/OpenViking) server: recall on each prompt, capture per turn, commit on session end and before compaction. Also exposes OpenViking's MCP tools. | `node` 18+ on `PATH`; an OpenViking server |
| [`openviking-wiki`](https://github.com/purisev/openviking-wiki) | An agent-authored Markdown wiki stored in OpenViking: `/wiki-init`, `/wiki-ingest`, `/wiki-query`, `/wiki-lint`, `/wiki-recover`. | `openviking-memory` (installed automatically); optionally `uv` or Python 3 with PyYAML for the offline helpers |

Enabling `openviking-memory` asks for the server URL and an API key. Every answer is optional: leave
them empty to keep using `~/.openviking/ovcli.conf` or the `OPENVIKING_*` environment variables.

Each plugin lives in its own repository, which holds its code, documentation and issues. This
repository holds only the catalog.

## Adding a plugin

1. Give the plugin repository a `.claude-plugin/plugin.json` with a `name` and a `version`, and check it
   with `claude plugin validate <checkout>/.claude-plugin/plugin.json`.
2. Add an entry to `.claude-plugin/marketplace.json` with the same `name` and a `github` source, and
   one to `.agents/plugins/marketplace.json` (Codex) with a `url` source for the same repository and a
   `policy`. A plugin for Codex also needs a `.codex-plugin/plugin.json`.
3. A plugin that needs another plugin from this catalog lists it under `dependencies` in its own
   `plugin.json`. A bare name resolves inside this marketplace, so Claude Code installs it
   automatically.
4. Run the checks below and open a pull request.

Do not give a plugin repository a `marketplace.json` of its own: the same plugin reachable through two
marketplaces can be enabled twice, and its hooks then run twice.

Claude Code tells plugin versions apart by `version` in `plugin.json`, so bump it with every release.

## Checks

```bash
node --test
claude plugin validate .
codex plugin marketplace add . && codex plugin list
```

`node --test` guards the catalogs' invariants, and that the two agree, without network access;
`claude plugin validate` checks the Claude Code one against its schema; `codex plugin list` shows
what Codex reads from the other.

The marketplace name `purisev` is part of every installed plugin's id (`<plugin>@purisev`) and of
users' settings. Renaming it would orphan those installs.
