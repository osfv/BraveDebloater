import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { buildArgs, partsToText, presetFeatureIds, type ManifestShape } from "../src/lib/command.ts";
import { judge, type SafetyManifest } from "../src/lib/safety.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const manifest = JSON.parse(readFileSync(join(root, "config", "policies.json"), "utf8")) as ManifestShape &
  SafetyManifest;

const policyFeatures = manifest.features.filter((f) => f.policies.length > 0);
const standard = presetFeatureIds(manifest, "Standard");
const high = presetFeatureIds(manifest, "High");
const extreme = presetFeatureIds(manifest, "Extreme");
const command = (ids: string[]) => {
  const parts = buildArgs(manifest, new Set(ids));
  return parts ? partsToText(parts) : null;
};

// The comparisons with the real script need PowerShell. CI must run them; a machine without pwsh skips them.
const hasPwsh = process.env.CI === "true" || spawnSync("pwsh", ["-NoProfile", "-Command", "exit 0"]).status === 0;
const pwsh = (args: string[], env: Record<string, string> = {}) => {
  const result = spawnSync("pwsh", ["-NoProfile", ...args], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, NO_COLOR: "1", ...env },
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout;
};

test("an empty selection builds no command", () => {
  assert.equal(command([]), null);
});

test("a selection that equals a preset uses the preset alone", () => {
  assert.equal(command(standard), "-Preset Standard");
  assert.equal(command(high), "-Preset High");
  assert.equal(command(extreme), "-Preset Extreme");
});

test("the presets nest: Standard inside High inside Extreme", () => {
  assert.ok(standard.length > 0 && standard.every((id) => high.includes(id)));
  assert.ok(high.length > standard.length && high.every((id) => extreme.includes(id)));
  assert.equal(extreme.length, policyFeatures.length, "a policy feature sits outside every preset");
});

test("a few named features use -OnlyFeature in manifest order", () => {
  assert.equal(command(["VPN", "Rewards", "Wallet"]), "-OnlyFeature Rewards,Wallet,VPN");
});

test("a selection near a preset names the difference", () => {
  const withoutTwo = extreme.filter((id) => id !== "News" && id !== "LeoAI");
  assert.equal(command(withoutTwo), "-Preset Extreme -ExcludeFeature LeoAI,News");
  assert.equal(command([...standard, "Translate"]), "-Preset Standard -IncludeFeature Translate");
});

test("profile-only features stay out of generated commands", () => {
  const profileOnly = manifest.features.filter((f) => f.policies.length === 0).map((f) => f.id);
  assert.ok(profileOnly.length > 0);
  assert.equal(command(profileOnly), null);
});

test("generated commands make the real script plan exactly the selected policies", { skip: !hasPwsh }, () => {
  const ids = policyFeatures.map((f) => f.id);
  const selections = [
    standard,
    high,
    extreme,
    ["Rewards"],
    extreme.filter((id) => id !== "News" && id !== "LeoAI"),
    [...standard, "Translate"],
    [...high.filter((id) => id !== "DeAmp"), "Autofill", "QRCodeGenerator"],
    ids.filter((_, index) => index % 3 === 0),
    ids.filter((_, index) => index % 2 === 1),
  ];
  for (const selection of selections) {
    const parts = buildArgs(manifest, new Set(selection));
    assert.ok(parts);
    const args = parts.flatMap((part) => (part.value ? [part.flag, part.value] : [part.flag]));
    const output = pwsh([
      "-File",
      join(root, "Invoke-BraveDebloat.ps1"),
      "-Platform",
      "Linux",
      "-PolicyPath",
      join(root, "site", "tests", "no-such-policy-file.json"),
      ...args,
    ]);
    const planned = [...output.matchAll(/Would set (\w+)/g)].map((match) => match[1]).sort();
    const expected = policyFeatures
      .filter((f) => selection.includes(f.id))
      .flatMap((f) => f.policies)
      .sort();
    assert.deepEqual(planned, expected, args.join(" "));
  }
});

test("blocked names are refused, whatever their case", () => {
  for (const name of manifest.safety.blockedPolicyNames) {
    const typed = name.toUpperCase();
    const verdict = judge(manifest, typed);
    assert.equal(verdict.kind, "refused");
    assert.equal(verdict.quote, `Refusing to apply protected policy '${typed}'.`);
  }
});

test("names that match a protected pattern are refused", () => {
  const verdict = judge(manifest, "MyShieldsDisabledList");
  assert.equal(verdict.kind, "refused");
  assert.equal(
    verdict.quote,
    "Refusing to apply 'MyShieldsDisabledList' because it matches protected pattern '.*ShieldsDisabled.*'.",
  );
});

test("managed policies are allowed and show the manifest value", () => {
  const verdict = judge(manifest, "braverewardsdisabled");
  assert.equal(verdict.kind, "allowed");
  assert.equal(verdict.quote, "BraveRewardsDisabled = 1");
  for (const name of Object.keys(manifest.policies)) {
    assert.equal(judge(manifest, name).kind, "allowed", `${name} is managed and blocked at once`);
  }
});

test("other names are reported as outside the manifest", () => {
  assert.equal(judge(manifest, "HomepageLocation").kind, "unlisted");
});

test("refusal messages match Assert-PolicySafety word for word", { skip: !hasPwsh }, () => {
  const names = [
    ...manifest.safety.blockedPolicyNames,
    "BRAVESYNCURL",
    "componentupdatesenabled",
    "MyShieldsDisabledList",
    "myshieldsdisabledlist",
    "SomeUpdateNowDisabledFlag",
  ];
  const script = [
    "$manifest = Get-Content -LiteralPath config/policies.json -Raw | ConvertFrom-Json",
    ". ./src/Common.ps1",
    ". ./src/Manifest.ps1",
    "foreach ($name in $env:SITE_TEST_NAMES -split ',') {",
    "  try { Assert-PolicySafety -PolicyNames @($name) -Manifest $manifest; 'allowed' }",
    "  catch { $_.Exception.Message }",
    "}",
  ].join("\n");
  const messages = pwsh(["-Command", script], { SITE_TEST_NAMES: names.join(",") })
    .split(/\r?\n/)
    .filter(Boolean);
  assert.deepEqual(
    messages,
    names.map((name) => judge(manifest, name).quote),
  );
});
