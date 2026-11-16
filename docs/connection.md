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
2. `~/.openviking/ovcli.conf`.
3. The `server` section of `~/.openviking/ov.conf`, the server's own configuration, on the machine that
   runs the server.
4. Nothing configured: Codex uses `http://127.0.0.1:1933` without a key. Claude Code keeps the plugin
   off.

Claude Code turns the plugin on only when `ovcli.conf` or `ov.conf` exists, or when
`OPENVIKING_MEMORY_ENABLED=1` is set. With the connection in environment variables alone, set that
variable too.

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
[OpenViking client configuration](https://github.com/volcengine/OpenViking/blob/v0.5.5/docs/en/configuration/02-client.md#plugin-settings) lists the keys.

A repository can carry its own settings in `.openviking/config.json`; see
[workspace configuration](https://github.com/volcengine/OpenViking/blob/v0.5.5/docs/en/configuration/02-client.md#workspace-configuration).

## Check it

Ask the agent to run the `ov-memory-doctor` skill. Its Configuration section names the source of every
value (`← ~/.openviking/ovcli.conf`, `← env`) and its Connection section proves the key against the
server: `/health` answers 200 even with a wrong key, so reachability alone proves nothing.
