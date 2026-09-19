# Connect to OpenViking

Both plugins talk to an [OpenViking](https://github.com/volcengine/OpenViking) server you run or have
access to. One file configures the connection for Claude Code and Codex alike:

`~/.openviking/ovcli.conf`

```json
{
  "url": "https://openviking.example.com",
  "api_key": "<a user or admin key>"
}
```

- `url` is the API root. It does not end in `/api/v1` or `/mcp`.
- `api_key` is a user or admin key. The server's root key is refused on the data APIs the plugins use.
- Keep the file private: `chmod 600 ~/.openviking/ovcli.conf`. The installer creates it that way.
- `account` and `user` are for servers in trusted mode, where identity comes from headers. With an
  API-key server, leave them out: the key already carries the identity.

## Where the connection comes from

First match wins:

1. `OPENVIKING_URL`, `OPENVIKING_API_KEY`, `OPENVIKING_ACCOUNT`, `OPENVIKING_USER` in the environment
   that launches the host.
2. Under Claude Code only: the answers to the prompts shown when the plugin is enabled (server URL, API
   key, account, user). Every answer is optional, and the key is kept in Claude Code's credential
   store. Change them later in `/plugin`.
3. `~/.openviking/ovcli.conf`.
4. Nothing configured: `http://127.0.0.1:1933` without a key, which suits a server on the same machine.

If you use both hosts, leave the Claude Code prompts empty and keep everything in `ovcli.conf`.
Otherwise the two hosts read the connection from different places, and a change to one does not reach
the other.

## Tuning

Behaviour settings go under `plugin` in the same file:

```json
{
  "url": "https://openviking.example.com",
  "api_key": "<key>",
  "plugin": {
    "recallLimit": 10,
    "codex": { "captureTimeoutMs": 25000 },
    "claude_code": { "debug": true }
  }
}
```

Keys directly under `plugin` apply to both hosts. `plugin.codex` applies under Codex only and
`plugin.claude_code` under Claude Code only; each overrides the shared value. The
[openviking-memory README](https://github.com/purisev/openviking-memory#configuration) lists the keys.

A repository can carry its own settings in `.openviking/config.json`; see the same README.

## Check it

Ask the agent to run the `ov-memory-doctor` skill. Its Configuration section names the source of every
value (`← ~/.openviking/ovcli.conf`, `← env`, `← Claude Code plugin option`) and its Connection section
proves the key against the server: `/health` answers 200 even with a wrong key, so reachability alone
proves nothing.
