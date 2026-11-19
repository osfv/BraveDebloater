export type SafetyManifest = {
  safety: { blockedPolicyNames: string[]; blockedNamePatterns: string[] };
  policies: Record<string, { value: unknown; reason: string }>;
};

export type Verdict = {
  kind: "refused" | "allowed" | "unlisted";
  name: string;
  quote?: string;
  note: string;
};

export const formatValue = (value: unknown) => (typeof value === "object" ? JSON.stringify(value) : String(value));

const BEFORE_WRITE = "The check runs before the backup and before any write.";

/** Mirrors Assert-PolicySafety in src/Manifest.ps1, including its messages and case-insensitive matching. */
export function judge(manifest: SafetyManifest, input: string): Verdict {
  const same = (name: string) => name.toLowerCase() === input.toLowerCase();

  const blocked = manifest.safety.blockedPolicyNames.find(same);
  if (blocked) {
    return {
      kind: "refused",
      name: blocked,
      quote: `Refusing to apply protected policy '${blocked}'.`,
      note: BEFORE_WRITE,
    };
  }

  const pattern = manifest.safety.blockedNamePatterns.find((p) => new RegExp(p, "i").test(input));
  if (pattern) {
    return {
      kind: "refused",
      name: input,
      quote: `Refusing to apply '${input}' because it matches protected pattern '${pattern}'.`,
      note: BEFORE_WRITE,
    };
  }

  const known = Object.keys(manifest.policies).find(same);
  if (known) {
    return {
      kind: "allowed",
      name: known,
      quote: `${known} = ${formatValue(manifest.policies[known].value)}`,
      note: manifest.policies[known].reason,
    };
  }

  return {
    kind: "unlisted",
    name: input,
    note: "BraveDebloater writes the policies in its manifest and nothing else. It has no switch for this one.",
  };
}
