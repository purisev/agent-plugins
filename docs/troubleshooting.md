# Troubleshooting

Start with the doctor. Ask the agent to run the `ov-memory-doctor` skill, or run it yourself from the
installed copy:

```sh
# Claude Code
node "$(claude plugin list --json | node -p 'JSON.parse(require("fs").readFileSync(0,"utf8")).find((p) => p.id.startsWith("openviking-memory@") && p.enabled).installPath')/scripts/ov-memory-doctor.mjs"

# Codex
node "$(ls -d ~/.codex/plugins/cache/purisev/openviking-memory/*/ | sort -V | tail -1)scripts/ov-memory-doctor.mjs"
```

It only reads. The report has sections for the environment, the plugin install, the configuration, the
connection, the server's health and recent activity, and ends with every failure and warning next to
its fix. Fix the first failure and run it again: one cause often shows up in several sections.

## Nothing happens at all

No recalled context, no tools, nothing logged.

- **`node` is not on `PATH`** for the environment that launched the host. The hooks and the MCP proxy
  cannot start. Under Claude Code the `/plugin` Errors tab shows `Executable not found in $PATH`. Install
  Node.js 18 or newer — the installer offers to — and restart the host. A shell profile that adds `node`
  to `PATH` does not help a host started from a desktop launcher.
- **Codex: the hooks were never approved.** Run `/hooks` and approve them. An update that changes the
  hooks needs approval again; the doctor lists the hooks that have no trust record.
- **Claude Code: `disableAllHooks`** is set in a settings file. The doctor names the file.
- **The plugin is disabled**, or Claude Code disabled it over a missing dependency. `claude plugin list`
  shows the state and the reason.

## `Host key verification failed` when a plugin installs or updates

Claude Code clones a plugin whose catalog entry has a `github` source over SSH, and fails on a machine
without an SSH key for GitHub. This catalog names every plugin by its https URL, so the error means
Claude Code still holds an older copy of the catalog. Run the installer again: it refreshes the
marketplace before it updates the plugins. By hand:

```sh
claude plugin marketplace update purisev && claude plugin update <plugin>@purisev
```

The same error from a plugin of another marketplace goes away when git takes GitHub's SSH addresses
over https:

```sh
git config --global url."https://github.com/".insteadOf "git@github.com:"
```

## Moving from the fork to the upstream plugin

`openviking-memory@purisev` used to come from the fork `purisev/openviking-memory`. It now comes from
the official OpenViking repository. Refresh the marketplace and update the plugin:

```sh
claude plugin marketplace update purisev && claude plugin update openviking-memory@purisev
codex plugin marketplace upgrade purisev && codex plugin add openviking-memory@purisev
```

Restart the host afterwards. Codex asks to approve the new hooks once (`/hooks`). Keys the fork read,
such as `plugin.codex.serverAutoCommit`, are ignored and can be removed from `ovcli.conf`.

## Every hook runs twice, or a skill is listed twice

The same plugin is enabled from two marketplaces, or a skill a plugin ships also sits loose in a skills
directory. The installer lists both kinds at the end of every run, and removes them when run with
`--remove-duplicates` (`-RemoveDuplicates` on Windows):

```sh
curl -fsSL https://ai-plugins.purisev.com/install.sh | sh -s -- --remove-duplicates
```

- **Another copy of a plugin**: a plugin with the name of a purisev plugin, installed from another
  marketplace out of the same repository, such as `humanizer@humanizer` from its author's marketplace.
  It is uninstalled, and its marketplace removed once nothing else is installed from it. A plugin that
  only shares the name, coming from a different repository, is left alone.
- **A loose copy of a skill**: a directory in `~/.claude/skills`, `~/.codex/skills` or `~/.agents/skills`
  named like a skill a purisev plugin ships, such as `~/.claude/skills/helm` next to `infra`. It moves
  to `<skills directory>.replaced/<date-time>/`, from where you can restore it.

Each removal asks first, unless `--yes` is given; `--dry-run` prints them and changes nothing. Looking
for duplicates needs `node`.

By hand, for a plugin: `claude plugin uninstall <plugin>@<marketplace>`, then
`claude plugin marketplace remove <marketplace>`; under Codex, `codex plugin remove` and
`codex plugin marketplace remove`.

## Recall is empty, captures do not land

- **The key is wrong.** `/health` answers 200 regardless, so look at the doctor's "credentials accepted"
  line, not at reachability.
- **The root key is in use.** It is refused on the data APIs. Use a user or admin key.
- **A stray `OPENVIKING_*` variable** overrides `ovcli.conf`. The doctor marks such values `← env`.
- **Settings sit under the other host's section.** `plugin.codex` does not apply under Claude Code, nor
  `plugin.claude_code` under Codex. Put shared settings directly under `plugin`.
- **The server cannot reach its embedding provider.** The doctor's Server health section shows `/ready`
  per subsystem; the fix is on the server.

## `404` on `profile.md`, `preferences`, `entities` in the server log

Expected for a new user. At session start the plugin looks for your profile and memory indexes, and the
server creates those only when it first extracts something to put there. The plugin treats the 404 as
"no profile yet"; the requests turn into 200 once the first memories exist.

## `POST /mcp` with API type `unknown` in the server log

That is the MCP proxy. Each host session opens with three requests (`initialize`, its confirmation and
`tools/list`), then one per tool call, and a `DELETE` on close. The proxy polls nothing. "unknown" is the
server's label for a path outside `/api/v1`.

## Logs

With `OPENVIKING_DEBUG=1` in the host's environment, or `"debug": true` in the plugin settings, hooks
and the proxy write JSON lines to `~/.openviking/logs/cc-hooks.log` (Claude Code) or
`~/.openviking/logs/codex-hooks.log` (Codex). An unchanged log after a full turn means the hooks were
never started: look at `node`, approval and enablement, not at the server.
