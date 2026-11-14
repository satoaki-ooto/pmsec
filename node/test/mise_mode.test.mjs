import { test } from "node:test";
import assert from "node:assert/strict";
import { minBin, path as legacyPath, supportsNewMode } from "../src/tools/mise.mjs";

// Every case pins PMSEC_MISE_VERSION, which is the same seam `preflight` uses,
// so the mode matrix never probes a host mise binary.
function ctxFor(version, globalFile) {
  const env = { PMSEC_MISE_VERSION: version, HOME: "/home/user" };
  if (globalFile !== undefined) env.MISE_GLOBAL_CONFIG_FILE = globalFile;
  return { env, home: "/home/user", platform: "linux" };
}

const VERSIONS = ["2026.11.0", "2026.10.25", "2026.12.0", "none"];
const GLOBAL_FILES = [undefined, "", "somewhere"];

// Only >= 2026.11.0 with MISE_GLOBAL_CONFIG_FILE absent or empty enables the new
// mode. Written as an explicit table rather than recomputing the gate, so a bug
// in the implementation cannot be mirrored by the expectation.
const EXPECTED = new Map([
  ["2026.11.0|absent", true],
  ["2026.11.0|empty", true],
  ["2026.11.0|set", false],
  ["2026.10.25|absent", false],
  ["2026.10.25|empty", false],
  ["2026.10.25|set", false],
  ["2026.12.0|absent", true],
  ["2026.12.0|empty", true],
  ["2026.12.0|set", false],
  ["none|absent", false],
  ["none|empty", false],
  ["none|set", false],
]);

function state(globalFile) {
  return globalFile === undefined ? "absent" : globalFile === "" ? "empty" : "set";
}

for (const version of VERSIONS) {
  for (const globalFile of GLOBAL_FILES) {
    const key = `${version}|${state(globalFile)}`;
    test(`supportsNewMode: mise ${version}, MISE_GLOBAL_CONFIG_FILE ${state(globalFile)} -> ${EXPECTED.get(key)}`, () => {
      assert.equal(supportsNewMode(ctxFor(version, globalFile)), EXPECTED.get(key));
    });
  }
}

test("supportsNewMode re-detects on every call, with no caching across a mutable ctx", () => {
  const ctx = ctxFor("2026.10.25");
  assert.equal(supportsNewMode(ctx), false);
  ctx.env.PMSEC_MISE_VERSION = "2026.11.0";
  assert.equal(supportsNewMode(ctx), true);
  ctx.env.MISE_GLOBAL_CONFIG_FILE = "/custom/config.toml";
  assert.equal(supportsNewMode(ctx), false);
  delete ctx.env.MISE_GLOBAL_CONFIG_FILE;
  assert.equal(supportsNewMode(ctx), true);
  ctx.env.MISE_GLOBAL_CONFIG_FILE = "";
  assert.equal(supportsNewMode(ctx), true);
  ctx.env.PMSEC_MISE_VERSION = "none";
  assert.equal(supportsNewMode(ctx), false);
  ctx.env.PMSEC_MISE_VERSION = "2026.12.0";
  assert.equal(supportsNewMode(ctx), true);
});

test("new-mode boundary is exactly 2026.11.0", () => {
  assert.equal(supportsNewMode(ctxFor("2026.10.99")), false);
  assert.equal(supportsNewMode(ctxFor("2026.11.0")), true);
  assert.equal(supportsNewMode(ctxFor("2027.0.0")), true);
});

test("the mode seam leaves the legacy path accessor and minBin untouched", () => {
  // The cooldown preflight floor stays at 2026.4.22; the new mode has its own gate.
  assert.deepEqual(minBin, [2026, 4, 22]);
  const norm = s => s.replace(/\\/g, "/");
  const ctx = ctxFor("2026.12.0");
  assert.equal(norm(legacyPath(ctx)), "/home/user/.config/mise/config.toml");
  assert.equal(
    norm(legacyPath({ ...ctx, env: { ...ctx.env, MISE_GLOBAL_CONFIG_FILE: "/custom/mise.toml" } })),
    "/custom/mise.toml",
  );
});
