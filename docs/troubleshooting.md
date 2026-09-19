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

## Every hook runs twice

The same plugin is enabled from two marketplaces — typically `openviking-memory@purisev` next to an
earlier `openviking-memory@openviking-memory`. The doctor reports "more than one copy". Remove the old
one:

```sh
claude plugin uninstall openviking-memory@openviking-memory
claude plugin marketplace remove openviking-memory
```

## Recall is empty, captures do not land

- **The key is wrong.** `/health` answers 200 regardless, so look at the doctor's "credentials accepted"
  line, not at reachability.
- **The root key is in use.** It is refused on the data APIs. Use a user or admin key.
- **A stray `OPENVIKING_*` variable** overrides `ovcli.conf`. The doctor marks such values `← env`.
- **Settings sit under the other host's section.** `plugin.codex` does not apply under Claude Code, nor
  `plugin.claude_code` under Codex. Put shared settings directly under `plugin`.
- **The server cannot reach its embedding provider.** The doctor's Server health section shows `/ready`
  per subsystem; the fix is on the server.

## The doctor says "no usable config" but memory works

Under Claude Code the connection may have been entered at the plugin's prompts. Claude Code hands those
answers to hooks and MCP servers, not to a shell, and keeps the key in its own credential store. The
doctor reads the non-sensitive answers from Claude Code's settings and says so; for its authenticated
checks, run it with `OPENVIKING_API_KEY` set in that shell.

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
