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

test("every plugin is fetched from its own GitHub repository", () => {
  for (const plugin of marketplace.plugins) {
    assert.equal(plugin.source?.source, "github", `${plugin.name} must use a github source`);
    assert.match(plugin.source.repo, /^[\w.-]+\/[\w.-]+$/);
  }
});

test("the README lists every plugin", () => {
  const readme = readFileSync(new URL("./README.md", import.meta.url), "utf-8");
  for (const plugin of marketplace.plugins) assert.ok(readme.includes(`\`${plugin.name}\``), `README does not mention ${plugin.name}`);
});

test("the Codex catalog publishes the same plugins under the same marketplace name", () => {
  assert.equal(codexCatalog.name, marketplace.name);
  assert.deepEqual(codexCatalog.plugins.map((p) => p.name).sort(), marketplace.plugins.map((p) => p.name).sort());
});

test("every Codex entry points at the repository its Claude Code entry names", () => {
  for (const plugin of codexCatalog.plugins) {
    const claudeEntry = marketplace.plugins.find((p) => p.name === plugin.name);
    // Codex has no `github` source type; it takes the clone URL.
    assert.equal(plugin.source?.source, "url");
    assert.equal(plugin.source.url, `https://github.com/${claudeEntry.source.repo}.git`);
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
