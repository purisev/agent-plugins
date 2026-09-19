# Plugins

## openviking-memory

Repository: [purisev/openviking-memory](https://github.com/purisev/openviking-memory)

Gives the agent a memory that outlives the session, kept on your OpenViking server.

- **Session start** — injects your profile and an index of stored preferences and entities.
- **Every prompt** — recalls memories relevant to it and adds them to the turn.
- **Every turn end** — appends the new messages to a server-side session.
- **Session end and before compaction** — commits the session, and the server extracts durable
  memories from it.
- **Tools** — a local MCP proxy exposes the server's tools to the agent: `search`, `find`, `read`,
  `list`, `tree`, `glob`, `grep`, `write`, `edit`, `remember`, `forget`, `add_resource`, `list_watches`,
  `cancel_watch`, `health`.

Needs Node.js 18 or newer on the `PATH` of the environment that launches the host: the hooks and the
proxy run the bare `node` command. At session start a small `sh` check tells the agent when `node` is
missing or too old, so it can offer to install it.

Skills: `openviking-memory` (how and when to use the tools), `ov-experience-memory`, and
`ov-memory-doctor` (diagnostics).

## openviking-wiki

Repository: [purisev/openviking-wiki](https://github.com/purisev/openviking-wiki)

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

## Platforms

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Installer | tested, including the Node.js download | same script; run in CI | `install.ps1`; run in CI |
| Plugins under Claude Code | tested | expected to work | hooks need `sh`, which Git for Windows provides |
| Plugins under Codex | install, hooks and MCP wiring tested | expected to work | not tested |

"Expected to work" means nothing platform-specific is known to be in the way, and nobody has checked.
