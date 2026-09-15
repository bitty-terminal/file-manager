/**
 * R24: negative manifest fixtures must be rejected.
 *
 * Runs the transitional validator (`scripts/validate-manifest.mjs`) against
 * every `validator-negative/*.toml` fixture and asserts each is rejected with a
 * non-zero exit. `validator-negative/base.toml` is the unmodified positive
 * control the negative fixtures derive from, so it is asserted to be accepted:
 * that proves the fixture set still discriminates rather than rejecting
 * everything.
 *
 * Fails (non-zero) when the fixture directory is missing, when any required
 * fixture is absent, or when no negative fixture remains, so the gate can never
 * pass vacuously.
 *
 * Usage:
 *
 *   bun tests/check-manifest-negative.mjs [fixture-dir]
 */

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, "..");
const VALIDATOR = join(REPO_ROOT, "scripts", "validate-manifest.mjs");
const DEFAULT_FIXTURE_DIR = join(REPO_ROOT, "validator-negative");
const POSITIVE_CONTROL = "base.toml";
const REQUIRED_NEGATIVES = [
  "bad-cap.toml",
  "bad-param.toml",
  "bare-fs.toml",
  "double-colon.toml",
  "fs-bool.toml",
  "unknown-key.toml",
];
const TIMEOUT_MS = 60_000;

function fail(message) {
  console.error(`manifest-negative: FAIL ${message}`);
  process.exit(1);
}

const fixtureDir = process.argv[2] ?? DEFAULT_FIXTURE_DIR;
if (!existsSync(fixtureDir) || !statSync(fixtureDir).isDirectory()) {
  fail(`fixture directory not found: ${fixtureDir}`);
}

const fixtures = readdirSync(fixtureDir)
  .filter((name) => name.endsWith(".toml"))
  .sort();
if (fixtures.length === 0) {
  fail(`no *.toml fixtures in ${fixtureDir}`);
}
if (!fixtures.includes(POSITIVE_CONTROL)) {
  fail(`missing positive control ${POSITIVE_CONTROL}`);
}
for (const required of REQUIRED_NEGATIVES) {
  if (!fixtures.includes(required)) {
    fail(`missing required negative fixture ${required}`);
  }
}

function validate(name) {
  const result = spawnSync(
    process.execPath,
    [VALIDATOR, join(fixtureDir, name)],
    { timeout: TIMEOUT_MS, encoding: "utf8" },
  );
  if (result.error !== undefined && result.error !== null) {
    process.stderr.write(result.stderr ?? "");
    fail(`validator could not run for ${name}: ${result.error.message}`);
  }
  return result;
}

let rejected = 0;
for (const name of fixtures) {
  if (name === POSITIVE_CONTROL) {
    const control = validate(name);
    if (control.status !== 0) {
      process.stderr.write(control.stderr ?? "");
      fail(`positive control ${name} was rejected (exit ${control.status})`);
    }
    console.log(`manifest-negative: OK control ${name} accepted`);
    continue;
  }
  const result = validate(name);
  if (result.status === 0) {
    process.stderr.write(result.stdout ?? "");
    fail(`negative fixture ${name} was accepted (exit 0)`);
  }
  rejected += 1;
  console.log(`manifest-negative: OK ${name} rejected (exit ${result.status})`);
}

console.log(
  `manifest-negative: OK ${rejected} negative fixture(s) rejected; ${POSITIVE_CONTROL} accepted`,
);
