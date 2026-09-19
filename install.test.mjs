import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

// Both installers run against stand-ins for claude, codex, git and node that log
// their arguments, so nothing is installed and no network is touched.

const WINDOWS = process.platform === "win32";
const SH_SCRIPT = fileURLToPath(new URL("./docs/install.sh", import.meta.url));
const PS_SCRIPT = fileURLToPath(new URL("./docs/install.ps1", import.meta.url));

function findOnPath(name) {
  const extensions = WINDOWS ? [".exe", ".cmd", ""] : [""];
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    for (const extension of extensions) {
      const candidate = join(dir, name + extension);
      if (dir && existsSync(candidate)) return candidate;
    }
  }
  return "";
}

const PWSH = findOnPath("pwsh");
const SH = findOnPath("sh");

// A stand-in is a node script plus the launcher the platform needs to call it by name.
function writeTool(binDir, name, body) {
  const script = join(binDir, `${name}.stub.cjs`);
  writeFileSync(script, body);
  if (WINDOWS) {
    writeFileSync(join(binDir, `${name}.cmd`), `@"${process.execPath}" "${script}" %*\r\n`);
  } else {
    const launcher = join(binDir, name);
    writeFileSync(launcher, `#!/bin/sh\nexec "${process.execPath}" "${script}" "$@"\n`);
    chmodSync(launcher, 0o755);
  }
}

function sandbox({ claudeMarketplaces = "", claudePlugins = "[]", codexMarketplaces = "", nodeVersion = "22.1.0", hosts = ["claude", "codex"] } = {}) {
  const root = mkdtempSync(join(tmpdir(), "agent-plugins-install-"));
  const bin = join(root, "bin");
  const home = join(root, "home");
  const log = join(root, "calls.log");
  mkdirSync(bin);
  mkdirSync(home);
  writeFileSync(log, "");

  const record = `require("fs").appendFileSync(${JSON.stringify(log)}, [${"NAME"}, ...process.argv.slice(2)].join(" ") + "\\n");`;
  const tool = (name, replies) => writeTool(bin, name, `
const args = process.argv.slice(2).join(" ");
${record.replace("NAME", JSON.stringify(name))}
const replies = ${JSON.stringify(replies)};
for (const [prefix, text] of Object.entries(replies)) if (args.startsWith(prefix)) process.stdout.write(text);
`);

  tool("git", { "--version": "git version 2.0.0\n" });
  if (nodeVersion) {
    writeTool(bin, "node", `
const args = process.argv.slice(2);
if (args[0] === "--version") console.log("v${nodeVersion}");
else if (args[0] === "-p") console.log("${nodeVersion.split(".")[0]}");
`);
  }
  if (hosts.includes("claude")) tool("claude", { "plugin marketplace list": claudeMarketplaces, "plugin list --json": claudePlugins });
  if (hosts.includes("codex")) tool("codex", { "plugin marketplace list": codexMarketplaces });

  return { root, bin, home, log, calls: () => readFileSync(log, "utf-8").split("\n").filter(Boolean) };
}

// Only calls that change something; listing and version probes are read-only.
function changes(calls) {
  return calls.filter((call) => /^(claude|codex) plugin /.test(call) && !/ (list|list --json)$/.test(call));
}

function systemPath() {
  if (WINDOWS) return [join(process.env.SystemRoot || "C:\\Windows", "System32"), join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0")];
  return ["/usr/bin", "/bin"];
}

function environment(box, extra = {}) {
  const env = { ...process.env, PATH: [box.bin, ...systemPath()].join(delimiter), HOME: box.home, USERPROFILE: box.home, ...extra };
  for (const name of ["OPENVIKING_URL", "OPENVIKING_BASE_URL", "OPENVIKING_CLI_CONFIG_FILE"]) if (!(name in extra)) delete env[name];
  return env;
}

const installers = [
  {
    name: "install.sh",
    skip: WINDOWS || !SH ? "needs a POSIX sh" : false,
    run: (box, flags, env) => spawnSync(SH, [SH_SCRIPT, ...flags.map((f) => ({ yes: "--yes", dryRun: "--dry-run" }[f] || f))], { env: environment(box, env), encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] }),
    hostFlag: (host) => ["--host", host],
    pluginFlag: (plugin) => ["--plugin", plugin],
  },
  {
    name: "install.ps1",
    skip: PWSH ? false : "needs pwsh",
    run: (box, flags, env) => spawnSync(PWSH, ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", PS_SCRIPT, ...flags.map((f) => ({ yes: "-Yes", dryRun: "-DryRun" }[f] || f))], { env: environment(box, env), encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] }),
    hostFlag: (host) => ["-AgentHost", host],
    pluginFlag: (plugin) => ["-Plugin", plugin],
  },
];

for (const installer of installers) {
  const it = (title, fn) => test(`${installer.name}: ${title}`, { skip: installer.skip }, fn);

  it("a first run adds the marketplace and installs both plugins into both hosts", () => {
    const box = sandbox();
    const result = installer.run(box, ["yes"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(changes(box.calls()), [
      "claude plugin marketplace add purisev/agent-plugins",
      "claude plugin install openviking-memory@purisev",
      "claude plugin install ov-wiki@purisev",
      "codex plugin marketplace add purisev/agent-plugins",
      "codex plugin add openviking-memory@purisev",
      "codex plugin add ov-wiki@purisev",
    ]);
    assert.match(result.stdout, /Codex: run \/hooks once/);
  });

  it("a repeat run refreshes what is already there", () => {
    const box = sandbox({
      claudeMarketplaces: "  ❯ purisev\n    Source: GitHub (purisev/agent-plugins)\n",
      claudePlugins: JSON.stringify([{ id: "openviking-memory@purisev" }]),
      codexMarketplaces: "MARKETPLACE  ROOT\npurisev      /somewhere\n",
    });
    const result = installer.run(box, ["yes"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(changes(box.calls()), [
      "claude plugin marketplace update purisev",
      "claude plugin update openviking-memory@purisev",
      "claude plugin install ov-wiki@purisev",
      "codex plugin marketplace upgrade purisev",
      "codex plugin add openviking-memory@purisev",
      "codex plugin add ov-wiki@purisev",
    ]);
  });

  it("a dry run changes nothing", () => {
    const box = sandbox();
    const result = installer.run(box, ["yes", "dryRun"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(changes(box.calls()), []);
    assert.match(result.stdout, /would run: claude plugin marketplace add purisev\/agent-plugins/);
    assert.ok(!existsSync(join(box.home, ".openviking")));
  });

  it("one host and one plugin can be chosen", () => {
    const box = sandbox();
    const result = installer.run(box, ["yes", ...installer.hostFlag("codex"), ...installer.pluginFlag("openviking-memory")]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(changes(box.calls()), [
      "codex plugin marketplace add purisev/agent-plugins",
      "codex plugin add openviking-memory@purisev",
    ]);
  });

  it("a missing node is reported and, without consent, not installed", () => {
    const box = sandbox({ nodeVersion: "", hosts: ["claude"] });
    const result = installer.run(box, []);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /node: not found/);
    assert.match(result.stdout + result.stderr, /stays inactive until Node\.js 18 or newer/);
    // pwsh keeps its own cache under ~/.local, so look only where Node.js would go.
    assert.ok(!existsSync(join(box.home, ".local", "lib", "nodejs")));
  });

  it("an outdated node is named as such", () => {
    const box = sandbox({ nodeVersion: "16.20.0", hosts: ["claude"] });
    const result = installer.run(box, []);
    assert.match(result.stdout, /v16\.20\.0 is older than 18/);
  });

  it("no supported host is an error, not a silent success", () => {
    const box = sandbox({ hosts: [] });
    const result = installer.run(box, ["yes"]);
    assert.notEqual(result.status, 0);
    assert.match(result.stdout + result.stderr, /neither claude nor codex/);
    assert.deepEqual(changes(box.calls()), []);
  });

  it("without a terminal the connection file is described, never written", () => {
    const box = sandbox({ hosts: ["claude"] });
    const result = installer.run(box, []);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /ovcli\.conf does not exist/);
    assert.ok(!existsSync(join(box.home, ".openviking")));
  });

  it("an existing connection file is left untouched", () => {
    const box = sandbox({ hosts: ["claude"] });
    mkdirSync(join(box.home, ".openviking"));
    const conf = join(box.home, ".openviking", "ovcli.conf");
    writeFileSync(conf, '{"url":"https://kept.example.com"}');
    const result = installer.run(box, ["yes"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /leaving it as it is/);
    assert.equal(readFileSync(conf, "utf-8"), '{"url":"https://kept.example.com"}');
  });
}

test("install.sh: an unknown option fails before anything runs", { skip: WINDOWS || !SH ? "needs a POSIX sh" : false }, () => {
  const box = sandbox();
  const result = spawnSync(SH, [SH_SCRIPT, "--frobnicate"], { env: environment(box), encoding: "utf-8" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unknown option: --frobnicate/);
  assert.deepEqual(box.calls(), []);
});

test("install.sh: a download cut short runs nothing", { skip: WINDOWS || !SH ? "needs a POSIX sh" : false }, () => {
  const lines = readFileSync(SH_SCRIPT, "utf-8").split("\n");
  for (const keep of [40, 150, lines.length - 3]) {
    const box = sandbox();
    const truncated = join(box.root, "truncated.sh");
    writeFileSync(truncated, lines.slice(0, keep).join("\n"));
    spawnSync(SH, [truncated, "--yes"], { env: environment(box), encoding: "utf-8" });
    assert.deepEqual(box.calls(), [], `the first ${keep} lines ran a command`);
  }
});

test("install.sh and install.ps1 install the same plugins from the same marketplace", () => {
  const sh = readFileSync(SH_SCRIPT, "utf-8");
  const ps = readFileSync(PS_SCRIPT, "utf-8");
  const marketplace = JSON.parse(readFileSync(new URL("./.claude-plugin/marketplace.json", import.meta.url), "utf-8"));
  const names = marketplace.plugins.map((plugin) => plugin.name);
  assert.match(sh, new RegExp(`ALL_PLUGINS="${names.join(" ")}"`));
  assert.match(ps, new RegExp(`\\$AllPlugins = @\\(${names.map((n) => `'${n}'`).join(", ")}\\)`));
  for (const script of [sh, ps]) {
    assert.ok(script.includes(`purisev/agent-plugins`));
    assert.ok(script.trimEnd().split("\n").at(-1).trim().toLowerCase().startsWith("main"), "the entry point must be the last line");
  }
});
