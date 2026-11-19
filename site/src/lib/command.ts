export type Feature = {
  id: string;
  label: string;
  reason: string;
  policies: string[];
};

export type ManifestShape = {
  presets: Record<string, string[]>;
  features: { id: string; label: string; reason: string; policies: string[] }[];
};

export const PRESET_NAMES = ["Standard", "High", "Extreme"] as const;
export type PresetName = (typeof PRESET_NAMES)[number];

export function resolvePreset(presets: Record<string, string[]>, name: string): string[] {
  const out: string[] = [];
  for (const entry of presets[name] ?? []) {
    const names = entry.startsWith("@") ? resolvePreset(presets, entry.slice(1)) : [entry];
    for (const n of names) if (!out.includes(n)) out.push(n);
  }
  return out;
}

/** Features a preset turns on. Profile-only features (no policies) stay out of the builder. */
export function presetFeatureIds(manifest: ManifestShape, name: PresetName): string[] {
  const policies = new Set(resolvePreset(manifest.presets, name));
  return manifest.features
    .filter((f) => f.policies.length > 0 && f.policies.every((p) => policies.has(p)))
    .map((f) => f.id);
}

export type CommandPart = { flag: string; value?: string };

/** The shortest argument list that selects exactly `selected`, in manifest order. */
export function buildArgs(manifest: ManifestShape, selected: ReadonlySet<string>): CommandPart[] | null {
  const ordered = manifest.features.filter((f) => f.policies.length > 0 && selected.has(f.id)).map((f) => f.id);
  if (ordered.length === 0) return null;

  let best: { cost: number; parts: CommandPart[] } = {
    cost: ordered.length,
    parts: [{ flag: "-OnlyFeature", value: ordered.join(",") }],
  };

  for (const name of PRESET_NAMES) {
    const inPreset = presetFeatureIds(manifest, name);
    const excluded = inPreset.filter((id) => !selected.has(id));
    const included = ordered.filter((id) => !inPreset.includes(id));
    const cost = excluded.length + included.length;
    if (cost < best.cost || cost === 0) {
      const parts: CommandPart[] = [{ flag: "-Preset", value: name }];
      if (included.length) parts.push({ flag: "-IncludeFeature", value: included.join(",") });
      if (excluded.length) parts.push({ flag: "-ExcludeFeature", value: excluded.join(",") });
      best = { cost, parts };
      if (cost === 0) break;
    }
  }
  return best.parts;
}

export function partsToText(parts: CommandPart[]): string {
  return parts.map((p) => (p.value ? p.flag + " " + p.value : p.flag)).join(" ");
}
