import { useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Check, Plus } from "@phosphor-icons/react";
import { PRESET_NAMES, buildArgs, partsToText, type Feature, type PresetName } from "../lib/command";
import { SCRIPT, features, manifest, policyValue, presetIds, sentenceCase, tiers } from "../lib/manifest";
import { CopyButton, EASE, Reveal, SectionHeading, cn } from "./ui";

const LAUNCHERS = [
  { id: "script", label: "Script", prefix: SCRIPT, hint: "Run it in the folder that holds the script." },
  { id: "scoop", label: "Scoop", prefix: "bravedebloat", hint: "The Scoop shim runs from any folder." },
];

const sameSet = (ids: string[], set: ReadonlySet<string>) => ids.length === set.size && ids.every((id) => set.has(id));

function Chip({
  feature,
  on,
  delay,
  onToggle,
  onInspect,
}: {
  feature: Feature;
  on: boolean;
  delay: number;
  onToggle: () => void;
  onInspect: () => void;
}) {
  return (
    <motion.button
      type="button"
      aria-pressed={on}
      onClick={onToggle}
      onPointerEnter={onInspect}
      onFocus={onInspect}
      whileTap={{ scale: 0.95 }}
      style={{ transitionDelay: delay + "ms" }}
      className={cn(
        "inline-flex h-10 items-center gap-2 rounded-ctl border pr-3.5 pl-2.5 text-[0.9375rem] transition-colors duration-300",
        on
          ? "border-transparent bg-text text-bg"
          : "border-line text-muted hover:border-line-strong hover:text-text",
      )}
    >
      <span className="relative grid size-4 place-items-center">
        <AnimatePresence initial={false}>
          <motion.span
            key={on ? "on" : "off"}
            className="absolute inset-0 grid place-items-center"
            initial={{ scale: 0.3, opacity: 0, rotate: -60 }}
            animate={{ scale: 1, opacity: 1, rotate: 0 }}
            exit={{ scale: 0.3, opacity: 0, rotate: 60 }}
            transition={{ duration: 0.28, delay: delay / 1000, ease: EASE }}
          >
            {on ? <Check size={15} weight="bold" /> : <Plus size={15} />}
          </motion.span>
        </AnimatePresence>
      </span>
      {sentenceCase(feature.label)}
    </motion.button>
  );
}

function ApplySwitch({ on, onChange }: { on: boolean; onChange: (next: boolean) => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      onClick={() => onChange(!on)}
      className="group inline-flex items-center gap-3 rounded-ctl text-sm font-medium"
    >
      <span
        className={cn(
          "flex h-6 w-11 items-center rounded-[0.45rem] p-0.5 transition-colors duration-300",
          on ? "justify-end bg-accent" : "justify-start bg-line-strong",
        )}
      >
        <motion.span
          layout
          transition={{ type: "spring", stiffness: 520, damping: 34 }}
          className={cn("block size-5 rounded-[0.33rem]", on ? "bg-on-accent" : "bg-surface")}
        />
      </span>
      <span>
        Add <code className="text-[0.8125rem]">-Apply</code>
      </span>
    </button>
  );
}

function Count({ value }: { value: number }) {
  return (
    <span className="relative inline-block overflow-hidden align-bottom">
      <AnimatePresence mode="popLayout" initial={false}>
        <motion.span
          key={value}
          className="inline-block font-medium text-text tabular-nums"
          initial={{ y: 12, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          exit={{ y: -12, opacity: 0 }}
          transition={{ duration: 0.25, ease: EASE }}
        >
          {value}
        </motion.span>
      </AnimatePresence>
    </span>
  );
}

export function Builder() {
  const [selected, setSelected] = useState<ReadonlySet<string>>(() => new Set(presetIds.Standard));
  const [apply, setApply] = useState(false);
  const [launcherId, setLauncherId] = useState(LAUNCHERS[0].id);
  const [inspected, setInspected] = useState(features[0].id);
  const [wave, setWave] = useState(false);
  const waveTimer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(waveTimer.current), []);

  const parts = useMemo(() => buildArgs(manifest, selected), [selected]);
  const activePreset = PRESET_NAMES.find((name) => sameSet(presetIds[name], selected)) ?? null;
  const chosen = features.filter((f) => selected.has(f.id));
  const policyCount = chosen.reduce((sum, f) => sum + f.policies.length, 0);
  const launcher = LAUNCHERS.find((item) => item.id === launcherId) ?? LAUNCHERS[0];
  const command = parts ? [launcher.prefix, partsToText(parts), apply && "-Apply"].filter(Boolean).join(" ") : "";
  const detail = features.find((f) => f.id === inspected) ?? features[0];

  function choosePreset(name: PresetName | null) {
    setWave(true);
    window.clearTimeout(waveTimer.current);
    waveTimer.current = window.setTimeout(() => setWave(false), 900);
    setSelected(new Set(name ? presetIds[name] : []));
  }

  function toggle(id: string) {
    setInspected(id);
    setSelected((prev) => {
      const next = new Set(prev);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  }

  return (
    <section id="features" className="wrap py-24 md:py-32">
      <SectionHeading title="Choose what goes">
        Start from a preset or pick single features. You get the PowerShell command to copy, and it previews first.
      </SectionHeading>

      <div className="mt-14 grid grid-cols-1 gap-10 lg:grid-cols-12 lg:gap-12">
        <Reveal className="lg:col-span-7">
          <div className="flex flex-wrap items-center gap-2">
            <div role="group" aria-label="Presets" className="inline-flex rounded-ctl border border-line bg-surface p-1">
              {PRESET_NAMES.map((name) => (
                <button
                  key={name}
                  type="button"
                  aria-pressed={activePreset === name}
                  aria-label={`${name}, ${presetIds[name].length} features`}
                  onClick={() => choosePreset(name)}
                  className={cn(
                    "relative h-9 rounded-[0.4rem] px-3.5 text-[0.9375rem] font-medium transition-colors duration-200",
                    activePreset === name ? "text-text" : "text-muted hover:text-text",
                  )}
                >
                  {activePreset === name && (
                    <motion.span
                      layoutId="preset-pill"
                      className="absolute inset-0 rounded-[0.4rem] bg-surface-2"
                      transition={{ type: "spring", stiffness: 420, damping: 36 }}
                    />
                  )}
                  <span className="relative">
                    {name}
                    <span className="ml-1.5 font-mono text-xs text-muted">{presetIds[name].length}</span>
                  </span>
                </button>
              ))}
            </div>
            <button
              type="button"
              onClick={() => choosePreset(null)}
              disabled={selected.size === 0}
              className="h-9 rounded-ctl px-3 text-[0.9375rem] text-muted transition-colors duration-200 hover:text-text disabled:pointer-events-none disabled:opacity-40"
            >
              Clear
            </button>
          </div>

          {tiers.map((tier) => (
            <div key={tier.title} className="mt-9 border-t border-line pt-4">
              <div className="flex items-baseline justify-between gap-4">
                <h3 className="font-medium">{tier.title}</h3>
                <span className="text-sm text-muted">{tier.note}</span>
              </div>
              <div className="mt-4 flex flex-wrap gap-2">
                {tier.features.map((feature) => (
                  <Chip
                    key={feature.id}
                    feature={feature}
                    on={selected.has(feature.id)}
                    delay={wave ? features.indexOf(feature) * 16 : 0}
                    onToggle={() => toggle(feature.id)}
                    onInspect={() => setInspected(feature.id)}
                  />
                ))}
              </div>
            </div>
          ))}
        </Reveal>

        <Reveal delay={0.1} className="lg:col-span-5">
          <div className="lg:sticky lg:top-24">
            <div className="rounded-panel border border-line bg-surface p-5 shadow-lift md:p-6">
              <div className="flex items-center justify-between gap-4 text-sm text-muted">
                <div role="group" aria-label="How you run the tool" className="inline-flex rounded-ctl border border-line p-0.5">
                  {LAUNCHERS.map((item) => (
                    <button
                      key={item.id}
                      type="button"
                      aria-pressed={launcher.id === item.id}
                      onClick={() => setLauncherId(item.id)}
                      className={cn(
                        "relative h-7 rounded-[0.5rem] px-2.5 text-[0.8125rem] font-medium transition-colors duration-200",
                        launcher.id === item.id ? "text-text" : "hover:text-text",
                      )}
                    >
                      {launcher.id === item.id && (
                        <motion.span
                          layoutId="launcher-pill"
                          className="absolute inset-0 rounded-[0.5rem] bg-surface-2"
                          transition={{ type: "spring", stiffness: 420, damping: 36 }}
                        />
                      )}
                      <span className="relative">{item.label}</span>
                    </button>
                  ))}
                </div>
                <span>
                  <Count value={chosen.length} /> {chosen.length === 1 ? "feature" : "features"},{" "}
                  <Count value={policyCount} /> {policyCount === 1 ? "policy" : "policies"}
                </span>
              </div>

              <div
                aria-live="polite"
                className="mt-4 min-h-[8.75rem] rounded-ctl bg-surface-2 p-4 font-mono text-[0.8125rem] leading-[1.75] break-words"
              >
                {parts ? (
                  <>
                    <span className="text-muted">{launcher.prefix}</span>
                    {parts.map((part) => (
                      <span key={part.flag}>
                        {" "}
                        <motion.span
                          className="inline-block text-accent-ink"
                          initial={{ opacity: 0, y: 6 }}
                          animate={{ opacity: 1, y: 0 }}
                          transition={{ duration: 0.3, ease: EASE }}
                        >
                          {part.flag}
                        </motion.span>{" "}
                        {part.value?.split(",").map((id, index, all) => (
                          <span key={id}>
                            <motion.span
                              className="inline-block"
                              initial={{ opacity: 0, y: 6 }}
                              animate={{ opacity: 1, y: 0 }}
                              transition={{ duration: 0.3, ease: EASE }}
                            >
                              {id}
                              {index < all.length - 1 && ","}
                            </motion.span>
                            <wbr />
                          </span>
                        ))}
                      </span>
                    ))}
                    <AnimatePresence initial={false}>
                      {apply && (
                        <motion.span
                          key="apply"
                          className="inline-block text-accent-ink"
                          initial={{ opacity: 0, x: -8 }}
                          animate={{ opacity: 1, x: 0 }}
                          exit={{ opacity: 0, x: -8 }}
                          transition={{ duration: 0.25, ease: EASE }}
                        >
                          &nbsp;-Apply
                        </motion.span>
                      )}
                    </AnimatePresence>
                  </>
                ) : (
                  <span className="font-sans text-sm text-muted">Pick a feature and the command appears here.</span>
                )}
              </div>

              <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
                <ApplySwitch on={apply} onChange={setApply} />
                <CopyButton text={command} label="Copy command" variant="solid" disabled={!parts} />
              </div>
              <p className="mt-4 text-sm leading-relaxed text-muted">
                {apply
                  ? "This run saves a backup, then writes the policies. Restart Brave when it finishes."
                  : "This run prints the plan and changes nothing."}{" "}
                {apply && launcher.id === "script" && "On Linux, start it with sudo pwsh. "}
                {launcher.hint}
              </p>
            </div>

            <div className="mt-6 min-h-[7rem] px-1">
              <AnimatePresence mode="wait" initial={false}>
                <motion.div
                  key={detail.id}
                  initial={{ opacity: 0, y: 8 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: -8 }}
                  transition={{ duration: 0.16 }}
                >
                  <p className="font-medium">{sentenceCase(detail.label)}</p>
                  <p className="mt-1 text-sm leading-relaxed text-muted">{detail.reason}</p>
                  <ul className="mt-2 font-mono text-xs leading-relaxed break-words text-muted">
                    {detail.policies.map((name) => (
                      <li key={name}>
                        {name} = {policyValue(name)}
                      </li>
                    ))}
                  </ul>
                </motion.div>
              </AnimatePresence>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
