# Adding a plugin

Each plugin lives in its own repository, which holds its code, reference documentation and issues.
[purisev/agent-plugins](https://github.com/purisev/agent-plugins) holds the two catalogs, the installer
and this site.

1. Give the plugin repository a `.claude-plugin/plugin.json` with a `name` and a `version`, and check it
   with `claude plugin validate <checkout>/.claude-plugin/plugin.json`. For Codex it also needs a
   `.codex-plugin/plugin.json`.
2. Add an entry with the same `name` to both catalogs:
   - `.claude-plugin/marketplace.json` — a `github` source;
   - `.agents/plugins/marketplace.json` — a `url` source for the same repository, and a `policy`.
     Codex has no `github` source type and lists nothing from the first file.
3. A plugin that needs another plugin from this catalog lists it under `dependencies` in its
   `.claude-plugin/plugin.json`. A bare name resolves inside this marketplace, so Claude Code installs
   it automatically.
4. Add the plugin to `ALL_PLUGINS` in `docs/install.sh` and to `$AllPlugins` and the `-Plugin`
   `ValidateSet` in `docs/install.ps1`, and give it a section in `docs/plugins.md`.
5. Run the checks and open a pull request.

Do not give a plugin repository a `marketplace.json` of its own. The same plugin reachable through two
marketplaces can be enabled twice, and its hooks then run twice.

Claude Code tells plugin versions apart by `version` in `plugin.json`, so raise it with every release.
Hooks shared by both hosts use `${CLAUDE_PLUGIN_ROOT}` in their commands: Claude Code expands only that
token, and Codex provides it next to its own `${PLUGIN_ROOT}`.

## Checks

```sh
node --test
claude plugin validate .
codex plugin marketplace add . && codex plugin list
mdbook build
```

`node --test` needs no network. It guards both catalogs and that they agree, and runs both installers
against stand-ins for `claude`, `codex`, `git` and `node`, so nothing is installed. The `install.ps1`
cases are skipped where `pwsh` is missing.

The marketplace name `purisev` is part of every installed plugin's id and of users' settings. Renaming
it would orphan those installs.
