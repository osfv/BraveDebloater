import { useRef, useState, type KeyboardEvent } from "react";
import { AnimatePresence, motion } from "motion/react";
import { ArrowUpRight } from "@phosphor-icons/react";
import { siAndroid, siApple, siIos, siLinux } from "simple-icons";
import { RELEASES } from "../lib/links";
import { CommandLine, EASE, Reveal, SectionHeading, cn } from "./ui";

const RAW = "https://raw.githubusercontent.com/osfv/BraveDebloater/main";

const TABS = [
  {
    id: "powershell",
    label: "PowerShell",
    command: "irm " + RAW + "/install.ps1 | iex",
    note: "Runs in Windows PowerShell 5.1 and in PowerShell 7 on Windows, macOS and Linux. The installer checks the release against SHA256SUMS.txt, stops on a mismatch and leaves Brave alone. It prints the preview command when it finishes.",
  },
  {
    id: "scoop",
    label: "Scoop",
    command: "scoop install " + RAW + "/packaging/scoop/bravedebloater.json",
    note: "Scoop adds a bravedebloat shim and keeps your backups folder across upgrades.",
  },
  {
    id: "manual",
    label: "Manual",
    command: "Get-FileHash .\\BraveDebloater-v*.zip -Algorithm SHA256",
    note: "Download the zip from the latest release, compare its hash with SHA256SUMS.txt, then extract it to a folder you control.",
    link: { href: RELEASES, label: "Open the latest release" },
  },
];

/** Brand marks from Simple Icons. The Windows mark is the one in assets/icons/windows.svg. */
const WINDOWS =
  "M0 3.39 9.74 2.06v9.4H0V3.39zm10.82-1.48L24 0v11.46H10.82V1.91zM0 12.54h9.74v9.4L0 20.61v-8.07zm10.82 0H24V24l-13.18-1.86v-9.6z";

const PLATFORMS = [
  { marks: [WINDOWS], name: "Windows", text: "Registry policy keys, for one user or the whole machine." },
  { marks: [siApple.path], name: "macOS", text: "defaults for one user, a managed plist for the machine." },
  { marks: [siLinux.path], name: "Linux", text: "One JSON file under /etc/brave/policies/managed." },
  {
    marks: [siAndroid.path, siIos.path],
    name: "Android and iOS",
    text: "MDM export files only. The tool writes nothing on the device.",
  },
];

function Mark({ path, size }: { path: string; size: number }) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} fill="currentColor" aria-hidden>
      <path d={path} />
    </svg>
  );
}

export function Install() {
  const [active, setActive] = useState(0);
  const tabs = useRef<(HTMLButtonElement | null)[]>([]);
  const tab = TABS[active];

  function onKeyDown(event: KeyboardEvent) {
    const step = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
    if (!step) return;
    event.preventDefault();
    const next = (active + step + TABS.length) % TABS.length;
    setActive(next);
    tabs.current[next]?.focus();
  }

  return (
    <section id="install" className="border-y border-line bg-surface">
      <div className="wrap py-24 md:py-32">
        <SectionHeading title="Install with one line">
          The installer puts the script in your user folder and keeps your backups when you upgrade. Scoop and a
          manual download work too.
        </SectionHeading>

        <div className="mt-14 grid grid-cols-1 gap-14 lg:grid-cols-12 lg:gap-x-12 lg:gap-y-16">
          <Reveal className="lg:col-span-12">
            <div role="tablist" aria-label="Install method" onKeyDown={onKeyDown} className="flex gap-6 border-b border-line">
              {TABS.map((item, index) => (
                <button
                  key={item.id}
                  ref={(node) => {
                    tabs.current[index] = node;
                  }}
                  type="button"
                  role="tab"
                  id={"tab-" + item.id}
                  aria-selected={active === index}
                  aria-controls="install-panel"
                  tabIndex={active === index ? 0 : -1}
                  onClick={() => setActive(index)}
                  className={cn(
                    "relative pb-3 font-medium transition-colors duration-200",
                    active === index ? "text-text" : "text-muted hover:text-text",
                  )}
                >
                  {item.label}
                  {active === index && (
                    <motion.span
                      layoutId="install-tab"
                      className="absolute inset-x-0 -bottom-px h-0.5 bg-accent"
                      transition={{ type: "spring", stiffness: 480, damping: 38 }}
                    />
                  )}
                </button>
              ))}
            </div>

            <div id="install-panel" role="tabpanel" aria-labelledby={"tab-" + tab.id} className="mt-6 min-h-[11rem]">
              <AnimatePresence mode="wait" initial={false}>
                <motion.div
                  key={tab.id}
                  initial={{ opacity: 0, y: 10 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: -10 }}
                  transition={{ duration: 0.22, ease: EASE }}
                >
                  <CommandLine text={tab.command} label={tab.label + " command"} large />
                  <p className="mt-5 max-w-[60ch] leading-relaxed text-muted">{tab.note}</p>
                  {tab.link && (
                    <a
                      href={tab.link.href}
                      className="group mt-4 inline-flex items-center gap-1.5 font-medium text-accent-ink underline decoration-accent-ink/40 underline-offset-4 transition-colors duration-200 hover:decoration-accent-ink"
                    >
                      {tab.link.label}
                      <ArrowUpRight
                        size={16}
                        weight="bold"
                        className="transition-transform duration-300 ease-out-expo group-hover:translate-x-0.5 group-hover:-translate-y-0.5"
                      />
                    </a>
                  )}
                </motion.div>
              </AnimatePresence>
            </div>
          </Reveal>

          <Reveal className="lg:col-span-4">
            <h3 className="text-xl font-medium tracking-[-0.02em]">Native writes on each platform</h3>
            <p className="mt-2 max-w-[36ch] leading-relaxed text-muted">
              PowerShell runs the tool on each system. The writes use that system's own policy format.
            </p>
          </Reveal>
          <Reveal delay={0.08} className="lg:col-span-8">
            <dl className="grid grid-cols-1 gap-x-10 gap-y-8 sm:grid-cols-2">
              {PLATFORMS.map(({ marks, name, text }) => (
                <div key={name} className="group flex gap-4">
                  <span className="flex h-12 w-12 shrink-0 items-center justify-center gap-1.5 rounded-ctl border border-line bg-bg text-text transition-[border-color,transform] duration-300 ease-out-expo group-hover:-translate-y-0.5 group-hover:border-line-strong">
                    {marks.map((path) => (
                      <Mark key={path.slice(0, 24)} path={path} size={marks.length > 1 ? 16 : 22} />
                    ))}
                  </span>
                  <div>
                    <dt className="font-medium">{name}</dt>
                    <dd className="mt-0.5 leading-relaxed text-muted">{text}</dd>
                  </div>
                </div>
              ))}
            </dl>
          </Reveal>
        </div>
      </div>
    </section>
  );
}
