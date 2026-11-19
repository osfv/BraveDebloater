import { useState, type FormEvent } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Check, Minus, Prohibit } from "@phosphor-icons/react";
import { blockedPolicyNames, manifest, policyValue } from "../lib/manifest";
import { EASE, Reveal, SectionHeading, cn } from "./ui";

const patterns = manifest.safety.blockedNamePatterns;
const managed = Object.keys(manifest.policies);

const ASKS = [
  { ask: "turn Shields off for a site", name: "BraveShieldsDisabledForUrls" },
  { ask: "stop component updates", name: "ComponentUpdatesEnabled" },
  { ask: "allowlist a domain in Safe Browsing", name: "SafeBrowsingAllowlistDomains" },
  { ask: "click through certificate errors", name: "SSLErrorOverrideAllowed" },
  { ask: "disable Brave Rewards", name: "BraveRewardsDisabled" },
  { ask: "set a homepage", name: "HomepageLocation" },
];

type Verdict = { kind: "refused" | "allowed" | "unlisted"; name: string; quote?: string; note: string };

const VERDICT = {
  refused: { label: "Refused", Icon: Prohibit, tone: "text-accent-ink" },
  allowed: { label: "Allowed", Icon: Check, tone: "text-text" },
  unlisted: { label: "Not in the manifest", Icon: Minus, tone: "text-muted" },
};

/** Mirrors Assert-PolicySafety in src/Manifest.ps1, including its messages and case-insensitive matching. */
function judge(input: string): Verdict {
  const same = (name: string) => name.toLowerCase() === input.toLowerCase();
  const beforeWrite = "The check runs before the backup and before any write.";

  const blocked = blockedPolicyNames.find(same);
  if (blocked) {
    return { kind: "refused", name: blocked, quote: `Refusing to apply protected policy '${blocked}'.`, note: beforeWrite };
  }
  const pattern = patterns.find((p) => new RegExp(p, "i").test(input));
  if (pattern) {
    return {
      kind: "refused",
      name: input,
      quote: `Refusing to apply '${input}' because it matches protected pattern '${pattern}'.`,
      note: beforeWrite,
    };
  }
  const known = managed.find(same);
  if (known) {
    return {
      kind: "allowed",
      name: known,
      quote: `${known} = ${policyValue(known)}`,
      note: manifest.policies[known].reason,
    };
  }
  return {
    kind: "unlisted",
    name: input,
    note: "BraveDebloater writes the policies in its manifest and nothing else. It has no switch for this one.",
  };
}

function Stage({ verdict }: { verdict: Verdict }) {
  const chars = [...verdict.name];
  const typed = chars.length * 0.014;
  const refused = verdict.kind === "refused";
  const { label, Icon, tone } = VERDICT[verdict.kind];

  return (
    <motion.div
      className="@container"
      initial={{ opacity: 1 }}
      animate={refused ? { x: [0, -10, 9, -6, 4, 0] } : { x: 0 }}
      exit={{ opacity: 0 }}
      transition={{ x: { duration: 0.45, delay: typed + 0.1 }, opacity: { duration: 0.12 } }}
    >
      <p
        aria-label={verdict.name}
        className="relative w-fit font-mono leading-none font-medium tracking-[-0.02em] whitespace-nowrap"
        style={{ fontSize: `min(4.25rem, ${(100 / (Math.max(chars.length, 14) * 0.6)).toFixed(3)}cqw)` }}
      >
        <span aria-hidden className={refused ? "text-muted" : "text-text"}>
          {chars.map((char, index) => (
            <motion.span
              key={index}
              className="inline-block"
              initial={{ opacity: 0, y: "0.4em" }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.32, delay: index * 0.014, ease: EASE }}
            >
              {char}
            </motion.span>
          ))}
        </span>
        {refused && (
          <motion.span
            aria-hidden
            className="absolute top-[54%] -right-[0.12em] -left-[0.12em] h-[0.085em] origin-left bg-accent"
            initial={{ scaleX: 0 }}
            animate={{ scaleX: 1 }}
            transition={{ duration: 0.45, delay: typed + 0.12, ease: [0.65, 0, 0.35, 1] }}
          />
        )}
      </p>

      <motion.div
        initial={{ opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, delay: typed + 0.3, ease: EASE }}
      >
        <p className={cn("mt-9 flex items-center gap-3 text-3xl font-semibold tracking-[-0.025em]", tone)}>
          <Icon size={28} weight="bold" />
          {label}
        </p>
        {verdict.quote && (
          <p className="mt-4 font-mono text-[0.9375rem] leading-relaxed break-words text-text">{verdict.quote}</p>
        )}
        <p className="mt-2 max-w-[56ch] leading-relaxed text-muted">{verdict.note}</p>
      </motion.div>
    </motion.div>
  );
}

export function Safety() {
  const [query, setQuery] = useState(ASKS[0].name);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);
  const verdict = judge(query);

  function submit(event: FormEvent) {
    event.preventDefault();
    const name = draft.trim();
    if (!name) return setError("Type a policy name first.");
    if (!/^[A-Za-z0-9_]+$/.test(name)) return setError("Policy names use letters, digits and underscores.");
    setError(null);
    setQuery(name);
  }

  return (
    <section id="safety" className="wrap py-24 md:py-32">
      <SectionHeading title="It refuses to weaken Brave">
        The manifest carries a blocklist. Ask for a policy that disables updates or Shields, or weakens Safe Browsing,
        and the run stops.
      </SectionHeading>

      <Reveal className="mt-14 grid grid-cols-1 gap-12 lg:grid-cols-12 lg:gap-0">
        <div className="lg:col-span-4 lg:pr-10">
          <p className="text-muted">Ask it to</p>
          <ul className="mt-2">
            {ASKS.map((item) => {
              const active = query === item.name;
              return (
                <li key={item.name}>
                  <button
                    type="button"
                    aria-pressed={active}
                    onClick={() => setQuery(item.name)}
                    className={cn(
                      "relative block w-full py-2 pl-5 text-left text-xl font-medium tracking-[-0.015em] transition-colors duration-200",
                      active ? "text-text" : "text-muted hover:text-text",
                    )}
                  >
                    {active && (
                      <motion.span
                        layoutId="ask-marker"
                        className="absolute top-2.5 bottom-2.5 left-0 w-0.5 bg-accent"
                        transition={{ type: "spring", stiffness: 460, damping: 36 }}
                      />
                    )}
                    {item.ask}
                  </button>
                </li>
              );
            })}
          </ul>

          <form onSubmit={submit} noValidate className="mt-8">
            <label htmlFor="policy-name" className="block text-sm font-medium">
              Or type a policy name
            </label>
            <div className="mt-2 flex gap-2">
              <input
                id="policy-name"
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
                maxLength={64}
                spellCheck={false}
                autoComplete="off"
                autoCapitalize="off"
                aria-invalid={error !== null}
                aria-describedby="policy-name-help"
                className="h-11 min-w-0 flex-1 rounded-ctl border border-line-strong bg-surface px-3.5 font-mono text-sm text-text transition-colors duration-200 focus-visible:border-accent-ink focus-visible:outline-offset-0"
              />
              <button
                type="submit"
                className="h-11 rounded-ctl border border-line-strong px-4 text-sm font-medium transition-[background-color,transform] duration-200 hover:bg-surface-2 active:scale-[0.97]"
              >
                Ask
              </button>
            </div>
            <p id="policy-name-help" className={cn("mt-2 text-sm leading-relaxed", error ? "text-accent-ink" : "text-muted")}>
              {error ?? "Patterns catch names the list does not spell out. Try MyShieldsDisabledList."}
            </p>
          </form>
        </div>

        <div className="flex flex-col lg:col-span-8 lg:border-l lg:border-line lg:pl-12">
          <div aria-live="polite" className="min-h-[15rem] lg:pt-1">
            <AnimatePresence mode="wait" initial={false}>
              <Stage key={verdict.kind + verdict.name} verdict={verdict} />
            </AnimatePresence>
          </div>

          <div className="mt-12 border-t border-line pt-6 lg:mt-auto">
            <p className="text-muted">
              The whole blocklist: {blockedPolicyNames.length} names and {patterns.length} patterns.
            </p>
            <ul className="mt-4 flex flex-wrap gap-x-6 gap-y-2 font-mono text-[0.8125rem] text-muted">
              {blockedPolicyNames.map((name) => (
                <li key={name}>
                  <button
                    type="button"
                    onClick={() => setQuery(name)}
                    className="underline decoration-line-strong underline-offset-4 transition-colors duration-200 hover:text-text hover:decoration-accent-ink"
                  >
                    {name}
                  </button>
                </li>
              ))}
              {patterns.map((pattern) => (
                <li key={pattern}>{pattern}</li>
              ))}
            </ul>
          </div>
        </div>
      </Reveal>
    </section>
  );
}
