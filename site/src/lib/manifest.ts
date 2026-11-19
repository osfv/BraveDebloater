import raw from "../../../config/policies.json";
import { PRESET_NAMES, presetFeatureIds, type Feature, type ManifestShape, type PresetName } from "./command";
import { formatValue, type SafetyManifest } from "./safety";

export const manifest = raw as unknown as ManifestShape & SafetyManifest;

export const SCRIPT = ".\\Invoke-BraveDebloat.ps1";

export const features: Feature[] = manifest.features.filter((f) => f.policies.length > 0);

export const presetIds: Record<PresetName, string[]> = {
  Standard: presetFeatureIds(manifest, "Standard"),
  High: presetFeatureIds(manifest, "High"),
  Extreme: presetFeatureIds(manifest, "Extreme"),
};

const tierOf = (id: string) => PRESET_NAMES.find((name) => presetIds[name].includes(id)) ?? null;

const tierMeta: { preset: PresetName | null; title: string; note: string }[] = [
  { preset: "Standard", title: "Brave extras and telemetry", note: "In Standard" },
  { preset: "High", title: "Privacy defaults", note: "High adds these" },
  { preset: "Extreme", title: "Extra interface", note: "Extreme adds these" },
  { preset: null, title: "Outside the presets", note: "Pick these by name" },
];

export const tiers = tierMeta
  .map((tier) => ({ ...tier, features: features.filter((f) => tierOf(f.id) === tier.preset) }))
  .filter((tier) => tier.features.length > 0);

export const blockedPolicyNames = manifest.safety.blockedPolicyNames;

export const sentenceCase = (label: string) => label.charAt(0).toUpperCase() + label.slice(1);

export const policyValue = (name: string) => formatValue(manifest.policies[name]?.value);
