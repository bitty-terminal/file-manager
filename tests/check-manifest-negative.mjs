/**
 * R24: negative manifest fixtures must be rejected by the authoritative SDK
 * linter, for the expected reason.
 *
 * Runs `bitty-plugin-lint` (bitty-plugin-sdk, R-SDK-2) against every
 * `validator-negative/*.toml` fixture. `validator-negative/base.toml` is the
 * accepted positive control and must be byte-identical to `bitty-plugin.toml`,
 * so the fixture set stays anchored to the shipped manifest shape. Every
 * negative must be rejected with exit code 1 and an error diagnostic, and each
 * fixture listed in {@link REQUIRED_NEGATIVES} must emit its expected
 * diagnostic code: a rejection for the wrong reason fails the gate.
 *
 * The linter is the commit-pinned devDependency resolved through
 * `node_modules/.bin`, so the gate runs offline and fails closed when the
 * pinned dependency is absent (`just install` materializes it). It also fails
 * (non-zero) when the fixture directory is missing, when the positive control
 * is missing or stale, or when a required fixture is absent, so the gate can
 * never pass vacuously.
 *
 * Usage:
 *
 *   bun tests/check-manifest-negative.mjs [fixture-dir]
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, "..");
const MANIFEST = join(REPO_ROOT, "bitty-plugin.toml");
const LINTER = join(REPO_ROOT, "node_modules", ".bin", "bitty-plugin-lint");
const DEFAULT_FIXTURE_DIR = join(REPO_ROOT, "validator-negative");
const POSITIVE_CONTROL = "base.toml";
const TIMEOUT_MS = 60_000;
const EXIT_INVALID = 1;

/**
 * Required negative fixtures and the diagnostic code each must trigger.
 * Removing a fixture, or changing its defect without updating this roster,
 * fails the gate.
 */
const REQUIRED_NEGATIVES = new Map([
  ["bad-cap.toml", "capabilities.unknown"],
  ["bad-param.toml", "capabilities.param-forbidden"],
  ["bare-fs.toml", "capabilities.param-required"],
  ["double-colon.toml", "capabilities.param-forbidden"],
  ["fs-bool.toml", "capabilities.value"],
  ["unknown-key.toml", "manifest.unknown-key"],
]);

function fail(message) {
  console.error(`manifest-negative: FAIL ${message}`);
  process.exit(1);
}

/** Diagnostic codes carried on `error:` lines of a human-mode report. */
function errorCodes(stdout) {
  const codes = new Set();
  for (const line of stdout.split("\n")) {
    const match = /: error: ([a-z][\w.-]*)/.exec(line);
    if (match !== null) {
      codes.add(match[1]);
    }
  }
  return codes;
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
for (const required of REQUIRED_NEGATIVES.keys()) {
  if (!fixtures.includes(required)) {
    fail(`missing required negative fixture ${required}`);
  }
}

if (!existsSync(LINTER)) {
  fail(`bitty-plugin-lint not found at ${LINTER}; run 'just install'`);
}

function lint(name) {
  const result = spawnSync(LINTER, [join(fixtureDir, name)], {
    timeout: TIMEOUT_MS,
    encoding: "utf8",
  });
  if (result.error !== undefined && result.error !== null) {
    process.stderr.write(result.stderr ?? "");
    fail(`linter could not run for ${name}: ${result.error.message}`);
  }
  return result;
}

if (
  !readFileSync(join(fixtureDir, POSITIVE_CONTROL)).equals(
    readFileSync(MANIFEST),
  )
) {
  fail(
    `positive control ${POSITIVE_CONTROL} is not byte-identical to bitty-plugin.toml`,
  );
}

const control = lint(POSITIVE_CONTROL);
if (control.status !== 0) {
  process.stderr.write(control.stderr ?? "");
  process.stdout.write(control.stdout ?? "");
  fail(
    `positive control ${POSITIVE_CONTROL} was rejected (exit ${control.status})`,
  );
}
console.log(`manifest-negative: OK control ${POSITIVE_CONTROL} accepted`);

let rejected = 0;
for (const name of fixtures) {
  if (name === POSITIVE_CONTROL) {
    continue;
  }
  const result = lint(name);
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  if (result.status === 0) {
    process.stdout.write(result.stdout ?? "");
    fail(`negative fixture ${name} was accepted (exit 0)`);
  }
  if (result.status !== EXIT_INVALID) {
    process.stderr.write(output);
    fail(
      `linter exited ${result.status} for ${name}; expected rejection (exit ${EXIT_INVALID})`,
    );
  }
  const codes = errorCodes(result.stdout ?? "");
  if (codes.size === 0) {
    process.stdout.write(result.stdout ?? "");
    fail(`negative fixture ${name} was rejected without an error diagnostic`);
  }
  const expected = REQUIRED_NEGATIVES.get(name);
  if (expected !== undefined && !codes.has(expected)) {
    process.stdout.write(result.stdout ?? "");
    fail(
      `${name} must emit '${expected}' but emitted: ${[...codes].sort().join(", ")}`,
    );
  }
  rejected += 1;
  console.log(
    `manifest-negative: OK ${name} rejected (exit ${result.status}; ${[...codes].sort().join(", ")})`,
  );
}

console.log(
  `manifest-negative: OK ${rejected} negative fixture(s) rejected; ${POSITIVE_CONTROL} accepted`,
);
