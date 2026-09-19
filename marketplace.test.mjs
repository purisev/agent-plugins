import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const marketplace = JSON.parse(readFileSync(new URL("./.claude-plugin/marketplace.json", import.meta.url), "utf-8"));
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
