import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";

// Both installers run against stand-ins for claude, codex, git and node that log
// their arguments, so nothing is installed and no network is touched.

const WINDOWS = process.platform === "win32";
const SH_SCRIPT = fileURLToPath(new URL("./docs/install.sh", import.meta.url));
const PS_SCRIPT = fileURLToPath(new URL("./docs/install.ps1", import.meta.url));
const LANGFUSE = "langfuse-observability";
const OPTIONAL_PLUGINS = [LANGFUSE];
const ALL_PLUGINS = JSON.parse(readFileSync(new URL("./.claude-plugin/marketplace.json", import.meta.url), "utf-8")).plugins.map((p) => p.name).filter((name) => !OPTIONAL_PLUGINS.includes(name));

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

// A stand-in package manager installs a stand-in for each package it is asked for.
const PACKAGE_MANAGER = `
const fs = require("fs");
const path = require("path");
const bin = path.dirname(process.argv[1]);
const args = process.argv.slice(2);
const packages = args[0] !== "install" ? [] : args.includes("--id") ? [args[args.indexOf("--id") + 1]] : args.slice(1).filter((a) => !a.startsWith("-"));
const ids = { "Git.Git": "git" };
for (const name of packages.map((p) => ids[p] ?? p)) {
  if (process.platform === "win32") fs.writeFileSync(path.join(bin, name + ".cmd"), "@echo " + name + " version 2.0.0\\r\\n");
  else fs.writeFileSync(path.join(bin, name), "#!/bin/sh\\necho '" + name + " version 2.0.0'\\n", { mode: 0o755 });
}
`;

// What a machine without git, and without any way to install it, has on its PATH.
const NO_GIT = ["git", "apt-get", "dnf", "yum", "zypper", "pacman", "apk", "brew", "sudo"];

function sandbox({ claudeMarketplaces = "", claudePlugins = "[]", codexMarketplaces = "", nodeVersion = "22.1.0", hosts = ["claude", "codex"], replies = {}, failing = [], git = true, uv = true, npm = true, hide = [], packageManager = "", uid = "" } = {}) {
  const root = mkdtempSync(join(tmpdir(), "agent-plugins-install-"));
  const bin = join(root, "bin");
  const home = join(root, "home");
  const log = join(root, "calls.log");
  const stdinLog = join(root, "stdin.log");
  mkdirSync(bin);
  mkdirSync(home);
  writeFileSync(log, "");
  writeFileSync(stdinLog, "");
  // A function builds the replies once the home directory exists, for replies that name files in it.
  if (typeof replies === "function") replies = replies(home);

  const record = `require("fs").appendFileSync(${JSON.stringify(log)}, [${"NAME"}, ...process.argv.slice(2)].join(" ") + "\\n");
if (process.argv.includes("--values-stdin")) require("fs").appendFileSync(${JSON.stringify(stdinLog)}, require("fs").readFileSync(0, "utf-8"));`;
  // A stand-in answers with the reply of the longest prefix that matches its arguments.
  const tool = (name, toolReplies) => writeTool(bin, name, `
const args = process.argv.slice(2).join(" ");
${record.replace("NAME", JSON.stringify(name))}
const replies = ${JSON.stringify(toolReplies)};
const prefix = Object.keys(replies).filter((p) => args.startsWith(p)).sort((a, b) => b.length - a.length)[0];
if (prefix !== undefined) process.stdout.write(replies[prefix]);
if (${JSON.stringify(failing)}.some((f) => \`${name} \${args}\`.startsWith(f))) process.exitCode = 1;
`);

  if (git) tool("git", { "--version": "git version 2.0.0\n" });
  if (uv) tool("uv", { "--version": "uv 0.13.9\n" });
  if (npm && nodeVersion) tool("npm", { "--version": "10.0.0\n" });
  if (packageManager) writeTool(bin, packageManager, `${record.replace("NAME", JSON.stringify(packageManager))}\n${PACKAGE_MANAGER}`);
  if (uid) {
    tool("id", { "-u": `${uid}\n` });
    writeTool(bin, "sudo", `${record.replace("NAME", '"sudo"')}
const [command, ...rest] = process.argv.slice(2);
process.exitCode = require("child_process").spawnSync(command, rest, { stdio: "inherit" }).status;
`);
  }
  if (nodeVersion) {
    writeTool(bin, "node", `
const args = process.argv.slice(2);
if (args[0] === "--version") console.log("v${nodeVersion}");
else if (args[0] === "-p") console.log("${nodeVersion.split(".")[0]}");
else process.exitCode = require("child_process").spawnSync(process.execPath, args, { stdio: "inherit" }).status;
`);
  }
  if (hosts.includes("claude")) tool("claude", { "plugin marketplace list": claudeMarketplaces, "plugin list --json": claudePlugins, ...replies.claude });
  if (hosts.includes("codex")) tool("codex", { "plugin marketplace list": codexMarketplaces, ...replies.codex });

  const path = [bin, ...(hide.length && !WINDOWS ? [filteredSystemPath(root, hide)] : systemPath())];
  return { root, bin, home, log, path, calls: () => readFileSync(log, "utf-8").split("\n").filter(Boolean), stdin: () => readFileSync(stdinLog, "utf-8") };
}

// The system's own tools, less the ones named, as links in one directory.
function filteredSystemPath(root, hide) {
  const dir = join(root, "system");
  mkdirSync(dir);
  // A Set, not existsSync: a dangling link reads as missing, and /bin may be /usr/bin.
  const linked = new Set(hide);
  for (const source of systemPath()) {
    for (const name of readdirSync(source)) {
      if (linked.has(name)) continue;
      linked.add(name);
      symlinkSync(join(source, name), join(dir, name));
    }
  }
  return dir;
}

// Only calls that change something; listing and version probes are read-only.
function changes(calls) {
  return calls.filter((call) => /^(claude|codex) plugin /.test(call) && !/ (list|list --json)$/.test(call) && !/^claude plugin configure \S+ --json$/.test(call));
}

function systemPath() {
  if (WINDOWS) return [join(process.env.SystemRoot || "C:\\Windows", "System32"), join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0")];
  return ["/usr/bin", "/bin"];
}

function environment(box, extra = {}) {
  const env = { ...process.env, PATH: box.path.join(delimiter), HOME: box.home, USERPROFILE: box.home, ...extra };
  for (const name of ["OPENVIKING_URL", "OPENVIKING_BASE_URL", "OPENVIKING_CLI_CONFIG_FILE", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "LANGFUSE_BASE_URL", "LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS"]) if (!(name in extra)) delete env[name];
  return env;
}

const SESSIONEND = "CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS";
const LANGFUSE_KEYS = { LANGFUSE_PUBLIC_KEY: "pk-lf-test", LANGFUSE_SECRET_KEY: "sk-lf-test" };

// A Langfuse server that accepts only LANGFUSE_KEYS. spawnSync blocks this thread, so it answers
// from a worker thread.
async function langfuseServer() {
  const worker = new Worker(`
    const { parentPort, workerData } = require("worker_threads");
    const expected = "Basic " + Buffer.from(workerData).toString("base64");
    const server = require("http").createServer((request, response) => {
      response.statusCode = request.url === "/api/public/projects" && request.headers.authorization === expected ? 200 : 401;
      response.end("{}");
    });
    server.listen(0, "127.0.0.1", () => parentPort.postMessage(server.address().port));
  `, { eval: true, workerData: `${LANGFUSE_KEYS.LANGFUSE_PUBLIC_KEY}:${LANGFUSE_KEYS.LANGFUSE_SECRET_KEY}` });
  const port = await new Promise((resolve) => worker.once("message", resolve));
  return { url: `http://127.0.0.1:${port}`, close: () => worker.terminate() };
}


const CATALOG = readFileSync(new URL("./.claude-plugin/marketplace.json", import.meta.url), "utf-8");

function writeFile(file, text) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, text);
}

// A machine where humanizer is also installed from its author's marketplace, where loose copies of
// helm and terraform sit next to a skill of the user's own, and where another marketplace offers an
// unrelated plugin that happens to be called playwright.
function duplicatesSandbox(options = {}) {
  let home;
  const box = sandbox({ ...options, replies: (h) => duplicateReplies((home = h)) });
  return { ...box, claudeDir: join(home, ".claude"), agentsSkills: join(home, ".agents", "skills") };
}

function duplicateReplies(home) {
  const claudeDir = join(home, ".claude");
  const codexDir = join(home, ".codex");
  const marketplace = (name) => join(claudeDir, "plugins", "marketplaces", name);
  writeFile(join(marketplace("purisev"), ".claude-plugin", "marketplace.json"), CATALOG);
  writeFile(join(marketplace("humanizer"), ".claude-plugin", "marketplace.json"), JSON.stringify({ plugins: [{ name: "humanizer", source: "./" }, { name: "extra", source: "./extra" }] }));
  writeFile(join(marketplace("official"), ".claude-plugin", "marketplace.json"), JSON.stringify({ plugins: [{ name: "playwright", source: { source: "url", url: "https://github.com/microsoft/playwright-mcp.git" } }] }));
  const cache = (name) => join(claudeDir, "plugins", "cache", "purisev", name, "1.0.0");
  writeFile(join(cache("humanizer"), "SKILL.md"), "---\n");
  writeFile(join(cache("infra"), "skills", "helm", "SKILL.md"), "---\n");
  writeFile(join(claudeDir, "skills", "helm", "SKILL.md"), "---\n");
  writeFile(join(claudeDir, "skills", "mine", "SKILL.md"), "---\n");

  const codexRoot = join(home, "codex-marketplaces", "purisev");
  writeFile(join(codexRoot, ".claude-plugin", "marketplace.json"), CATALOG);
  writeFile(join(codexDir, "plugins", "cache", "purisev", "infra", "1.0.0", "skills", "terraform", "SKILL.md"), "---\n");
  writeFile(join(home, ".agents", "skills", "terraform", "SKILL.md"), "---\n");

  const claude = {
    "plugin marketplace list --json": JSON.stringify([
      { name: "purisev", source: "github", repo: "purisev/agent-plugins", installLocation: marketplace("purisev") },
      { name: "humanizer", source: "github", repo: "blader/humanizer", installLocation: marketplace("humanizer") },
      { name: "official", source: "github", repo: "example/official", installLocation: marketplace("official") },
    ]),
    "plugin list --json": JSON.stringify([
      { id: "humanizer@purisev", installPath: cache("humanizer") },
      { id: "infra@purisev", installPath: cache("infra") },
      { id: "humanizer@humanizer", installPath: join(claudeDir, "plugins", "cache", "humanizer", "humanizer", "2.9.1") },
      { id: "extra@humanizer", installPath: join(claudeDir, "plugins", "cache", "humanizer", "extra", "1.0.0") },
      { id: "playwright@official", installPath: join(claudeDir, "plugins", "cache", "official", "playwright", "1.0.0") },
    ]),
  };
  const codex = {
    "plugin marketplace list --json": JSON.stringify({ marketplaces: [
      { name: "purisev", root: codexRoot },
      { name: "humanizer", root: join(home, "codex-marketplaces", "humanizer"), marketplaceSource: { sourceType: "git", source: "https://github.com/blader/humanizer.git" } },
    ] }),
    "plugin list --json": JSON.stringify({ installed: [
      { pluginId: "infra@purisev", name: "infra", marketplaceName: "purisev", version: "1.0.0", installed: true, source: { source: "git-subdir", url: "https://github.com/purisev/agent-skills.git", path: "infra" } },
      { pluginId: "humanizer@humanizer", name: "humanizer", marketplaceName: "humanizer", version: "4.0.0", installed: true, source: { source: "local", path: "/elsewhere" }, marketplaceSource: { sourceType: "git", source: "https://github.com/blader/humanizer.git" } },
    ] }),
  };
  return { claude, codex };
}

const replaced = (skillsDir, name) => {
  const parent = `${skillsDir}.replaced`;
  return existsSync(parent) && readdirSync(parent).some((stamp) => existsSync(join(parent, stamp, name, "SKILL.md")));
};
const removals = (calls) => changes(calls).filter((call) => / (uninstall|remove) /.test(call));

const installers = [
  {
    name: "install.sh",
    skip: WINDOWS || !SH ? "needs a POSIX sh" : false,
    run: (box, flags, env) => spawnSync(SH, [SH_SCRIPT, ...flags.map((f) => ({ yes: "--yes", dryRun: "--dry-run", removeDuplicates: "--remove-duplicates", langfuse: "--langfuse" }[f] || f))], { env: environment(box, env), encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] }),
    hostFlag: (host) => ["--host", host],
    pluginFlag: (plugin) => ["--plugin", plugin],
  },
  {
    name: "install.ps1",
    skip: PWSH ? false : "needs pwsh",
    run: (box, flags, env) => spawnSync(PWSH, ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", PS_SCRIPT, ...flags.map((f) => ({ yes: "-Yes", dryRun: "-DryRun", removeDuplicates: "-RemoveDuplicates", langfuse: "-Langfuse" }[f] || f))], { env: environment(box, env), encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] }),
    hostFlag: (host) => ["-AgentHost", host],
    pluginFlag: (plugin) => ["-Plugin", plugin],
  },
];

for (const installer of installers) {
  const it = (title, fn) => test(`${installer.name}: ${title}`, { skip: installer.skip }, fn);

  it("a first run adds the marketplace and installs every plugin into both hosts", () => {
    const box = sandbox();
    const result = installer.run(box, ["yes"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(changes(box.calls()), [
      "claude plugin marketplace add purisev/agent-plugins",
      ...ALL_PLUGINS.map((plugin) => `claude plugin install ${plugin}@purisev`),
      "codex plugin marketplace add purisev/agent-plugins",
      ...ALL_PLUGINS.map((plugin) => `codex plugin add ${plugin}@purisev`),
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
      ...ALL_PLUGINS.slice(1).map((plugin) => `claude plugin install ${plugin}@purisev`),
      "codex plugin marketplace upgrade purisev",
      ...ALL_PLUGINS.map((plugin) => `codex plugin add ${plugin}@purisev`),
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

  it("duplicates are listed, and nothing is removed, without the flag", () => {
    const box = duplicatesSandbox();
    const result = installer.run(box, ["yes"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(removals(box.calls()), []);
    assert.match(result.stdout, /humanizer@humanizer: another copy of humanizer@purisev/);
    assert.match(result.stdout, /helm: a loose copy of a skill infra@purisev ships/);
    assert.match(result.stdout, /terraform: a loose copy of a skill infra@purisev ships/);
    assert.match(result.stdout, /again with -?-remove-?duplicates/i);
    assert.doesNotMatch(result.stdout, /playwright@official|mine/);
    assert.ok(existsSync(join(box.claudeDir, "skills", "helm", "SKILL.md")));
  });

  it("with the flag, duplicates go and everything else stays", () => {
    const box = duplicatesSandbox();
    const result = installer.run(box, ["yes", "removeDuplicates"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    // The humanizer marketplace stays under Claude Code, where extra@humanizer is still installed from it.
    assert.deepEqual(removals(box.calls()), [
      "claude plugin uninstall humanizer@humanizer",
      "codex plugin remove humanizer@humanizer",
      "codex plugin marketplace remove humanizer",
    ]);
    assert.ok(!existsSync(join(box.claudeDir, "skills", "helm")));
    assert.ok(replaced(join(box.claudeDir, "skills"), "helm"));
    assert.ok(!existsSync(join(box.agentsSkills, "terraform")));
    assert.ok(replaced(box.agentsSkills, "terraform"));
    assert.ok(existsSync(join(box.claudeDir, "skills", "mine", "SKILL.md")));
  });

  it("a dry run with the flag removes and moves nothing", () => {
    const box = duplicatesSandbox();
    const result = installer.run(box, ["yes", "dryRun", "removeDuplicates"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(changes(box.calls()), []);
    assert.match(result.stdout, /would run: claude plugin uninstall humanizer@humanizer/);
    assert.match(result.stdout, /would move .*helm/);
    assert.ok(existsSync(join(box.claudeDir, "skills", "helm", "SKILL.md")));
  });

  it("a removal that fails is reported and the installer carries on", () => {
    const box = duplicatesSandbox({ failing: ["claude plugin uninstall"] });
    const result = installer.run(box, ["yes", "removeDuplicates"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout + result.stderr, /could not remove humanizer@humanizer; continuing/);
    assert.ok(removals(box.calls()).includes("codex plugin remove humanizer@humanizer"));
    assert.ok(replaced(join(box.claudeDir, "skills"), "helm"));
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

  it("without git and a way to install it, the installer stops before touching the hosts", () => {
    const box = sandbox({ git: false, hide: NO_GIT });
    const result = installer.run(box, ["yes"]);
    assert.notEqual(result.status, 0);
    assert.match(result.stdout + result.stderr, /git is needed/);
    assert.deepEqual(changes(box.calls()), []);
  });

  it("without consent uv is not installed, and what that costs is named", () => {
    const box = sandbox({ uv: false, hosts: ["claude"] });
    const result = installer.run(box, ["langfuse"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /uv: not found; Claude Code runs the Langfuse hook with it/);
    assert.match(result.stdout + result.stderr, /Claude Code sends no traces to Langfuse until uv is on PATH/);
    assert.ok(!existsSync(join(box.home, ".local", "bin", "uv")));
  });

  it("Codex with Langfuse needs Node.js 22, and says so", () => {
    const box = sandbox({ nodeVersion: "20.0.0", hosts: ["codex"] });
    const result = installer.run(box, ["langfuse"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /v20\.0\.0 is older than 22/);
    assert.match(result.stdout + result.stderr, /Codex sends no traces to Langfuse until Node\.js 22 or newer is on PATH/);
  });

  it("a node without npm gets npm for Langfuse's Codex plugin", { skip: installer.name === "install.ps1" && !WINDOWS ? "install.ps1 downloads Node.js on Windows only" : false }, () => {
    const box = sandbox({ nodeVersion: "24.0.0", npm: false, hosts: ["codex"] });
    const result = installer.run(box, ["yes", "dryRun", "langfuse"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /npm: not found; Codex installs Langfuse's plugin with it/);
    assert.match(result.stdout, installer.name === "install.sh" ? /would link npm npx into/ : /would download the latest Node\.js v22/);
  });

  it("without npm, Codex skips Langfuse's plugin and the run goes on", () => {
    const box = sandbox({ nodeVersion: "24.0.0", npm: false, hosts: ["codex"] });
    const result = installer.run(box, ["langfuse"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout + result.stderr, /skipping tracing@purisev: Codex installs it with npm, which is not on PATH/);
    assert.deepEqual(changes(box.calls()), [
      "codex plugin marketplace add purisev/agent-plugins",
      ...ALL_PLUGINS.map((plugin) => `codex plugin add ${plugin}@purisev`),
    ]);
    assert.match(result.stdout, /==> Langfuse/);
  });

  it("uv is offered for the Langfuse hook in Claude Code", { skip: installer.name === "install.ps1" && !WINDOWS ? "install.ps1 downloads uv on Windows only" : false }, () => {
    const box = sandbox({ uv: false, hosts: ["claude"] });
    const result = installer.run(box, ["yes", "dryRun", "langfuse"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /would download https:\/\/github\.com\/astral-sh\/uv\/releases\/latest\/download\/uv-\S+\.(tar\.gz|zip)/);
    assert.ok(!existsSync(join(box.home, ".local", "bin")));
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

  it("Langfuse is installed into both hosts on request, and keys the server accepts are saved", async () => {
    const server = await langfuseServer();
    try {
      const box = sandbox();
      const result = installer.run(box, ["yes", "langfuse"], { LANGFUSE_BASE_URL: `${server.url}/`, ...LANGFUSE_KEYS });
      assert.equal(result.status, 0, result.stderr + result.stdout);
      assert.deepEqual(changes(box.calls()), [
        "claude plugin marketplace add purisev/agent-plugins",
        ...[...ALL_PLUGINS, LANGFUSE].map((plugin) => `claude plugin install ${plugin}@purisev`),
        "codex plugin marketplace add purisev/agent-plugins",
        ...[...ALL_PLUGINS, "tracing"].map((plugin) => `codex plugin add ${plugin}@purisev`),
        `claude plugin configure ${LANGFUSE}@purisev --values-stdin`,
      ]);
      const expected = { base_url: server.url, public_key: LANGFUSE_KEYS.LANGFUSE_PUBLIC_KEY, secret_key: LANGFUSE_KEYS.LANGFUSE_SECRET_KEY };
      assert.deepEqual(JSON.parse(box.stdin()), { LANGFUSE_BASE_URL: expected.base_url, ...LANGFUSE_KEYS });
      const conf = join(box.home, ".codex", "langfuse.json");
      assert.deepEqual(JSON.parse(readFileSync(conf, "utf-8")), { enabled: true, ...expected });
      if (!WINDOWS) assert.equal(statSync(conf).mode & 0o777, 0o600);
    } finally {
      await server.close();
    }
  });

  it("Langfuse keys the server refuses are not saved", async () => {
    const server = await langfuseServer();
    try {
      const box = sandbox();
      const result = installer.run(box, ["yes", "langfuse"], { LANGFUSE_BASE_URL: server.url, ...LANGFUSE_KEYS, LANGFUSE_SECRET_KEY: "sk-lf-wrong" });
      assert.equal(result.status, 0, result.stderr + result.stdout);
      assert.match(result.stdout + result.stderr, /did not accept the keys \(HTTP 401\)/);
      assert.ok(!changes(box.calls()).some((call) => call.includes("--values-stdin")));
      assert.ok(!existsSync(join(box.home, ".codex", "langfuse.json")));
    } finally {
      await server.close();
    }
  });

  it("without Langfuse keys and without a terminal, nothing is asked or saved", () => {
    const box = sandbox();
    const result = installer.run(box, ["yes", "langfuse"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /No Langfuse keys saved/);
    assert.ok(!changes(box.calls()).some((call) => call.includes("--values-stdin")));
    assert.ok(!existsSync(join(box.home, ".codex", "langfuse.json")));
  });

  it("a dry run with Langfuse saves no keys", () => {
    const box = sandbox();
    const result = installer.run(box, ["yes", "dryRun", "langfuse"], { LANGFUSE_BASE_URL: "http://127.0.0.1:9", ...LANGFUSE_KEYS });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(changes(box.calls()), []);
    assert.match(result.stdout, /would check the keys against http:\/\/127\.0\.0\.1:9 and save them for: claude codex/);
    assert.ok(!existsSync(join(box.home, ".codex", "langfuse.json")));
  });

  it("an installed Langfuse plugin stays up to date without the flag, and its saved keys are kept", () => {
    const box = sandbox({
      claudePlugins: JSON.stringify([{ id: `${LANGFUSE}@purisev` }]),
      replies: { claude: { [`plugin configure ${LANGFUSE}@purisev --json`]: JSON.stringify({ configured: ["LANGFUSE_SECRET_KEY", "LANGFUSE_PUBLIC_KEY"] }) } },
    });
    const conf = join(box.home, ".codex", "langfuse.json");
    writeFile(conf, '{"enabled":true}');
    const result = installer.run(box, ["yes"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const calls = changes(box.calls());
    assert.ok(calls.includes(`claude plugin update ${LANGFUSE}@purisev`), calls.join("\n"));
    assert.ok(calls.includes("codex plugin add tracing@purisev"), calls.join("\n"));
    assert.ok(!calls.some((call) => call.includes("--values-stdin")));
    assert.match(result.stdout, /Claude Code has the Langfuse keys; leaving them as they are/);
    assert.equal(readFileSync(conf, "utf-8"), '{"enabled":true}');
  });

  it("Claude Code gets time at exit for the Langfuse hook, and the rest of its settings stay", () => {
    const box = sandbox({ hosts: ["claude"] });
    const settings = join(box.home, ".claude", "settings.json");
    writeFile(settings, JSON.stringify({ model: "opus", env: { KEPT: "1" } }));
    const result = installer.run(box, ["yes", "langfuse"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(JSON.parse(readFileSync(settings, "utf-8")), { model: "opus", env: { KEPT: "1", [SESSIONEND]: "15000" } });
    assert.match(result.stdout, /set CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS to 15000 in /);
  });

  it("Claude Code's settings file is created for the Langfuse hook's time at exit", () => {
    const box = sandbox({ hosts: ["claude"] });
    const result = installer.run(box, ["yes", "langfuse"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const settings = join(box.home, ".claude", "settings.json");
    assert.deepEqual(JSON.parse(readFileSync(settings, "utf-8")), { env: { [SESSIONEND]: "15000" } });
  });

  it("a time at exit already in Claude Code's settings is kept", () => {
    const box = sandbox({ hosts: ["claude"] });
    const settings = join(box.home, ".claude", "settings.json");
    writeFile(settings, JSON.stringify({ env: { [SESSIONEND]: "5000" } }));
    const result = installer.run(box, ["yes", "langfuse"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /sets CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS to 5000; leaving it as it is/);
    assert.equal(readFileSync(settings, "utf-8"), JSON.stringify({ env: { [SESSIONEND]: "5000" } }));
  });

  it("Claude Code's settings are not edited without consent, in a dry run, or when they are not JSON", () => {
    const box = sandbox({ hosts: ["claude"] });
    const settings = join(box.home, ".claude", "settings.json");
    const declined = installer.run(box, ["langfuse"]);
    assert.equal(declined.status, 0, declined.stderr + declined.stdout);
    assert.match(declined.stdout + declined.stderr, /not editing .*the last turn of each session never reaches Langfuse/);
    const dryRun = installer.run(box, ["yes", "dryRun", "langfuse"]);
    assert.match(dryRun.stdout, /would set CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS to 15000 in /);
    assert.ok(!existsSync(settings));
    writeFile(settings, "{ not json");
    const broken = installer.run(box, ["yes", "langfuse"]);
    assert.equal(broken.status, 0, broken.stderr + broken.stdout);
    assert.match(broken.stdout + broken.stderr, /cannot be read as JSON/);
    assert.equal(readFileSync(settings, "utf-8"), "{ not json");
  });

  it("without Langfuse, Claude Code's settings are left alone", () => {
    const box = sandbox({ hosts: ["claude"] });
    const result = installer.run(box, ["yes"]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.ok(!existsSync(join(box.home, ".claude", "settings.json")));
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

const shTest = (title, fn) => test(`install.sh: ${title}`, { skip: WINDOWS || !SH ? "needs a POSIX sh" : false }, fn);
const runSh = (box, flags, env) => installers[0].run(box, flags, env);

shTest("a missing git is installed with the package manager before any plugin", () => {
  const box = sandbox({ git: false, hide: NO_GIT, packageManager: "apt-get", uid: "1000" });
  const result = runSh(box, ["yes"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const calls = box.calls();
  const install = calls.indexOf("sudo apt-get install -y -qq git");
  assert.ok(calls.includes("sudo apt-get update -qq"), calls.join("\n"));
  assert.ok(install >= 0, calls.join("\n"));
  assert.ok(install < calls.indexOf("claude plugin marketplace add purisev/agent-plugins"));
  assert.match(result.stdout, /git: git version 2\.0\.0/);
});

shTest("as root the package manager runs without sudo", () => {
  const box = sandbox({ git: false, hide: NO_GIT, packageManager: "apt-get", uid: "0" });
  const result = runSh(box, ["yes"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.ok(box.calls().includes("apt-get install -y -qq git"));
  assert.ok(!box.calls().some((call) => call.startsWith("sudo ")));
});

shTest("a missing git is not installed without consent", () => {
  const box = sandbox({ git: false, hide: NO_GIT, packageManager: "apt-get", uid: "1000" });
  const result = runSh(box, []);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /git is needed/);
  assert.ok(!box.calls().some((call) => call.includes("apt-get")));
  assert.deepEqual(changes(box.calls()), []);
});

shTest("curl is installed before a download that needs it", () => {
  const box = sandbox({ uv: false, hosts: ["claude"], hide: ["curl", ...NO_GIT.slice(1)], packageManager: "apt-get", uid: "1000" });
  const result = runSh(box, ["yes", "dryRun", "langfuse"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /curl: not found; needed to download it/);
  assert.match(result.stdout, /would run: sudo apt-get install -y -qq curl/);
  assert.match(result.stdout, /would download https:\/\/github\.com\/astral-sh\/uv\//);
});

test("install.ps1: a missing git is installed with winget before any plugin", { skip: WINDOWS && PWSH ? false : "needs Windows and pwsh" }, () => {
  const box = sandbox({ git: false, packageManager: "winget" });
  const result = installers[1].run(box, ["yes"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const calls = box.calls();
  const install = calls.findIndex((call) => call.startsWith("winget install --id Git.Git"));
  assert.ok(install >= 0, calls.join("\n"));
  assert.ok(install < calls.indexOf("claude plugin marketplace add purisev/agent-plugins"));
});

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

test("install.sh and install.ps1 look for duplicates with the same program", () => {
  // A Windows checkout may carry CRLF line ends.
  const read = (file) => readFileSync(file, "utf-8").replace(/\r\n/g, "\n");
  const sh = read(SH_SCRIPT).match(/^duplicates_js\(\) \{\n  cat <<'JS'\n([\s\S]*?)\nJS\n\}/m)[1];
  const ps = read(PS_SCRIPT).match(/^function Get-DuplicateFinder \{\n  return @'\n([\s\S]*?)\n'@\n\}/m)[1];
  assert.equal(ps, sh);
});

test("install.sh and install.ps1 check Langfuse keys with the same program", () => {
  const read = (file) => readFileSync(file, "utf-8").replace(/\r\n/g, "\n");
  const sh = read(SH_SCRIPT).match(/^langfuse_check_js\(\) \{\n  cat <<'JS'\n([\s\S]*?)\nJS\n\}/m)[1];
  const ps = read(PS_SCRIPT).match(/^function Get-LangfuseCheck \{\n  return @'\n([\s\S]*?)\n'@\n\}/m)[1];
  assert.equal(ps, sh);
});

test("install.sh and install.ps1 set Claude Code's time at exit with the same program", () => {
  const read = (file) => readFileSync(file, "utf-8").replace(/\r\n/g, "\n");
  const sh = read(SH_SCRIPT).match(/^sessionend_timeout_js\(\) \{\n  cat <<'JS'\n([\s\S]*?)\nJS\n\}/m)[1];
  const ps = read(PS_SCRIPT).match(/^function Get-SessionEndTimeoutSetter \{\n  return @'\n([\s\S]*?)\n'@\n\}/m)[1];
  assert.equal(ps, sh);
});

test("install.sh and install.ps1 install the same plugins from the same marketplace", () => {
  const sh = readFileSync(SH_SCRIPT, "utf-8");
  const ps = readFileSync(PS_SCRIPT, "utf-8");
  const marketplace = JSON.parse(readFileSync(new URL("./.claude-plugin/marketplace.json", import.meta.url), "utf-8"));
  const names = marketplace.plugins.map((plugin) => plugin.name);
  assert.deepEqual([...ALL_PLUGINS, ...OPTIONAL_PLUGINS].sort(), [...names].sort());
  const quoted = (list) => list.map((n) => `'${n}'`).join(", ");
  assert.match(sh, new RegExp(`ALL_PLUGINS="${ALL_PLUGINS.join(" ")}"`));
  assert.match(sh, new RegExp(`OPTIONAL_PLUGINS="${OPTIONAL_PLUGINS.join(" ")}"`));
  assert.match(ps, new RegExp(`\\$AllPlugins = @\\(${quoted(ALL_PLUGINS)}\\)`));
  assert.match(ps, new RegExp(`\\[ValidateSet\\(${quoted([...ALL_PLUGINS, ...OPTIONAL_PLUGINS])}\\)\\]`));
  for (const script of [sh, ps]) {
    assert.ok(script.includes(`purisev/agent-plugins`));
    assert.ok(script.trimEnd().split("\n").at(-1).trim().toLowerCase().startsWith("main"), "the entry point must be the last line");
  }
});
