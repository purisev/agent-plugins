# Adding a plugin

A plugin purisev maintains lives in its own repository, such as
[purisev/openviking-wiki](https://github.com/purisev/openviking-wiki), or as a directory of
[purisev/agent-skills](https://github.com/purisev/agent-skills), which suits plugins made only of
skills. [purisev/agent-plugins](https://github.com/purisev/agent-plugins) holds the two catalogs, the
installer and this site. Plugins from other authors follow [Third-party plugins](#third-party-plugins).

1. Give the plugin repository a `.claude-plugin/plugin.json` with a `name` and a `version`, and check it
   with `claude plugin validate <checkout>/.claude-plugin/plugin.json`. For Codex it also needs a
   `.codex-plugin/plugin.json`.
2. Add an entry with the same `name` to both catalogs:
   - `.claude-plugin/marketplace.json` — a `github` source, or a `git-subdir` source for a directory of
     purisev/agent-skills, with no `ref`, so it follows the default branch;
   - `.agents/plugins/marketplace.json` — a `url` or `git-subdir` source for the same place with
     `"ref": "main"`, and a `policy`. Codex has no `github` source type and lists nothing from the
     first file.
3. A plugin that needs another plugin from this catalog lists it under `dependencies` in its
   `.claude-plugin/plugin.json`. A bare name resolves inside this marketplace, so Claude Code installs
   it automatically.
4. Add the plugin to `ALL_PLUGINS` in `docs/install.sh` and to `$AllPlugins` and the `-Plugin`
   `ValidateSet` in `docs/install.ps1`, and give it a section in `docs/plugins.md`.
5. Run the checks and open a pull request.

Do not give a plugin repository a `marketplace.json` of its own. The same plugin reachable through two
marketplaces can be enabled twice, and its hooks then run twice.

Claude Code tells plugin versions apart by `version` in `plugin.json`, so raise it with every release.

## Third-party plugins

A plugin from another author is listed from its own repository and pinned to one commit, so an install
never follows someone else's branch:

- **Claude Code**: a `github`, `url` or `git-subdir` source with `ref` (the release tag, or the branch
  when there are no releases) and `sha` (the full commit). A source without `.claude-plugin/plugin.json`
  needs no wrapper: the catalog entry is then its manifest, so give it `description`, `version`,
  `author`, `license` and `skills`, as the `playwright` entry does.
- **Codex**: the same repository, `ref` and `sha`, when the source has a manifest Codex reads and its
  skills under `skills/`. Otherwise Codex installs the plugin empty, without an error. Such a plugin
  gets a Codex-only copy in purisev/agent-skills, whose README describes the layout, and joins
  `CODEX_WRAPPERS` in `marketplace.test.mjs`.

An install that succeeds does not prove that Codex found the skills. `codex debug prompt-input hi`
prints the prompt Codex would send, and its skills section lists every skill it loaded.

To move a third-party plugin to a new release, change `ref` and `sha` in both catalogs, and for a
wrapper follow the update steps in the purisev/agent-skills README.
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
