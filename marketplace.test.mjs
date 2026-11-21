import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";

const marketplace = JSON.parse(readFileSync(new URL("./.claude-plugin/marketplace.json", import.meta.url), "utf-8"));
const codexCatalog = JSON.parse(readFileSync(new URL("./.agents/plugins/marketplace.json", import.meta.url), "utf-8"));
const KEBAB_CASE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

test("the marketplace keeps the name installed plugin ids are built from", () => {
  assert.equal(marketplace.name, "purisev");
  assert.ok(marketplace.owner?.name);
});

test("every plugin has a unique kebab-case name and a description", () => {
  const names = marketplace.plugins.map((plugin) => plugin.name);
  assert.ok(names.length > 0);
  assert.deepEqual(names, [...new Set(names)]);
  for (const plugin of marketplace.plugins) {
    assert.match(plugin.name, KEBAB_CASE);
    assert.ok(plugin.description?.trim(), `${plugin.name} needs a description`);
  }
});

// Plugins maintained by purisev follow the default branch of their repository. Third-party plugins
// are pinned to a commit, with the release tag or branch it came from as `ref`, so an install never
// follows someone else's branch.
const OWN = /^https:\/\/github\.com\/purisev\//;
const SHA = /^[0-9a-f]{40}$/;
const RELEASE_TAG = /^v\d+\.\d+\.\d+(\.\d+)?$/;
const AGENT_SKILLS = "https://github.com/purisev/agent-skills.git";
// openviking-memory ships a separate plugin directory per host.
const CODEX_PATHS = { "openviking-memory": "examples/codex-memory-plugin" };
// Codex finds skills only in a plugin with a manifest and a skills/ directory. These sources have
// neither, so Codex installs a copy kept in purisev/agent-skills, which checks it against the commit
// pinned here.
const CODEX_WRAPPERS = ["humanizer", "playwright"];
// Codex installs a plugin only under the name in its manifest. Langfuse publishes its Codex plugin
// separately, as an npm package named tracing.
const CODEX_NAMES = { "langfuse-observability": "tracing" };
const CODEX_NPM = { tracing: "@langfuse/codex-observability-plugin" };
const EXACT_VERSION = /^\d+\.\d+\.\d+$/;
const codexName = (name) => CODEX_NAMES[name] ?? name;

// Claude Code clones a `github` source over SSH and does not fall back to HTTPS, so it fails on a
// machine without an SSH key for GitHub. An https clone URL works everywhere.
test("every plugin is cloned over https", () => {
  for (const plugin of marketplace.plugins) {
    assert.ok(["url", "git-subdir"].includes(plugin.source?.source), `${plugin.name} must use a url or git-subdir source`);
    assert.match(plugin.source.url, /^https:\/\/.+\.git$/, plugin.name);
    if (plugin.source.source === "git-subdir") assert.ok(plugin.source.path, `${plugin.name} needs a path`);
  }
});

test("every plugin follows its own repository or is pinned to a third-party commit", () => {
  for (const plugin of marketplace.plugins) {
    const { source } = plugin;
    if (OWN.test(source.url)) {
      assert.equal(source.ref, undefined, `${plugin.name} must follow its default branch`);
      assert.equal(source.sha, undefined, `${plugin.name} must follow its default branch`);
    } else {
      assert.match(source.sha ?? "", SHA, `${plugin.name} must be pinned to a commit`);
      assert.ok(source.ref, `${plugin.name} must name the tag or branch of its commit`);
    }
  }
});

test("a third-party release tag is pinned together with its commit", () => {
  for (const plugin of marketplace.plugins.filter((p) => !OWN.test(p.source.url))) {
    if (plugin.source.ref.startsWith("v")) assert.match(plugin.source.ref, RELEASE_TAG, plugin.name);
  }
});

test("the README lists every plugin", () => {
  const readme = readFileSync(new URL("./README.md", import.meta.url), "utf-8");
  for (const plugin of marketplace.plugins) assert.ok(readme.includes(`\`${plugin.name}\``), `README does not mention ${plugin.name}`);
});

test("the Codex catalog publishes the same plugins under the same marketplace name", () => {
  assert.equal(codexCatalog.name, marketplace.name);
  assert.deepEqual(codexCatalog.plugins.map((p) => p.name).sort(), marketplace.plugins.map((p) => codexName(p.name)).sort());
});

test("every Codex entry installs what its Claude Code entry names", () => {
  for (const plugin of codexCatalog.plugins) {
    const claude = marketplace.plugins.find((p) => codexName(p.name) === plugin.name).source;
    if (CODEX_NPM[plugin.name]) {
      assert.equal(plugin.source.source, "npm", plugin.name);
      assert.equal(plugin.source.package, CODEX_NPM[plugin.name], plugin.name);
      assert.match(plugin.source.version ?? "", EXACT_VERSION, `${plugin.name} must be pinned to a release`);
    } else if (CODEX_WRAPPERS.includes(plugin.name)) {
      assert.deepEqual(plugin.source, { source: "git-subdir", url: AGENT_SKILLS, path: plugin.name, ref: "main" });
    } else {
      assert.deepEqual(plugin.source, {
        source: claude.source,
        url: claude.url,
        ...(claude.source === "git-subdir" && { path: CODEX_PATHS[plugin.name] ?? claude.path }),
        ref: claude.ref ?? "main",
        ...(claude.sha && { sha: claude.sha }),
      });
    }
  }
});

test("every Codex wrapper stands in for a listed third-party plugin", () => {
  for (const name of CODEX_WRAPPERS) {
    const claude = marketplace.plugins.find((p) => p.name === name);
    assert.ok(claude, `${name} is listed`);
    assert.ok(!OWN.test(claude.source.url), `${name} is third-party`);
  }
});

test("every Codex entry declares the install policy Codex needs to offer it", () => {
  for (const plugin of codexCatalog.plugins) {
    assert.ok(["AVAILABLE", "INSTALLED_BY_DEFAULT", "NOT_AVAILABLE"].includes(plugin.policy?.installation), plugin.name);
    assert.ok(["ON_INSTALL", "ON_USE"].includes(plugin.policy?.authentication), plugin.name);
  }
});

test("the custom domain is declared in the site's source only", () => {
  // Pages serves gh-pages, which gets its CNAME from docs/. GitHub adds a CNAME to
  // the repository root when the domain is saved while main is the Pages source.
  assert.equal(readFileSync(new URL("./docs/CNAME", import.meta.url), "utf-8").trim(), "ai-plugins.purisev.com");
  assert.ok(!existsSync(new URL("./CNAME", import.meta.url)));
});

test("the former plugin name is declared as a rename and no longer listed", () => {
  assert.deepEqual(marketplace.renames, { "openviking-wiki": "ov-wiki" });
  assert.ok(marketplace.plugins.some((plugin) => plugin.name === "ov-wiki"));
  assert.ok(!marketplace.plugins.some((plugin) => plugin.name === "openviking-wiki"));
});
