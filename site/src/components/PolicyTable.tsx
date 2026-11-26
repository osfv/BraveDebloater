import { motion } from "motion/react";
import { EASE, Reveal, SectionHeading, cn } from "./ui";

const COLUMNS = ["Survives Brave updates", "Visible in brave://policy", "Undo", "Touches binaries, hosts or extensions"];

const ROWS = [
  { name: "BraveDebloater policies", cells: ["Yes", "Yes", "Backup restore", "No"], ours: true },
  { name: "brave://settings toggles", cells: ["Updates can reset them", "No", "Manual", "No"] },
  { name: "A random .reg gist", cells: ["Maybe", "If the gist used policies", "Needs a copy you kept", "Sometimes"] },
  {
    name: "Scripts that disable Shields or updates",
    cells: ["Yes, but they weaken Brave", "Yes", "Painful", "Sometimes"],
  },
];

export function PolicyTable() {
  return (
    <section id="why" className="wrap py-24 md:py-32">
      <SectionHeading title="Brave can reset settings. It enforces policies.">
        Policies load on each start, show up in brave://policy and come off when you restore the backup.
      </SectionHeading>

      <table className="mt-14 hidden w-full border-separate border-spacing-0 text-left md:table">
        <thead>
          <tr>
            <th scope="col" className="w-[26%] px-5 pb-4">
              <span className="sr-only">Approach</span>
            </th>
            {COLUMNS.map((column) => (
              <th key={column} scope="col" className="px-5 pb-4 align-bottom text-sm font-normal text-muted">
                {column}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {ROWS.map((row, index) => (
            <motion.tr
              key={row.name}
              initial={{ opacity: 0, y: 16 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.6 }}
              transition={{ duration: 0.6, delay: index * 0.08, ease: EASE }}
              className={cn(row.ours ? "font-medium" : "text-muted")}
            >
              <th
                scope="row"
                className={cn(
                  "px-5 py-5 font-medium text-text",
                  row.ours ? "rounded-l-ctl bg-accent-soft" : index > 1 && "border-t border-line",
                )}
              >
                {row.name}
              </th>
              {row.cells.map((cell, i) => (
                <td
                  key={COLUMNS[i]}
                  className={cn(
                    "px-5 py-5",
                    row.ours ? "bg-accent-soft text-text" : index > 1 && "border-t border-line",
                    row.ours && i === row.cells.length - 1 && "rounded-r-ctl",
                  )}
                >
                  {cell}
                </td>
              ))}
            </motion.tr>
          ))}
        </tbody>
      </table>

      <div className="mt-12 grid gap-3 md:hidden">
        {ROWS.map((row) => (
          <Reveal key={row.name}>
            <div
              className={cn(
                "rounded-panel border p-5",
                row.ours ? "border-accent/25 bg-accent-soft" : "border-line bg-surface",
              )}
            >
              <h3 className="font-medium">{row.name}</h3>
              <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
                {row.cells.map((cell, i) => (
                  <div key={COLUMNS[i]}>
                    <dt className="text-muted">{COLUMNS[i]}</dt>
                    <dd className="mt-0.5 font-medium">{cell}</dd>
                  </div>
                ))}
              </dl>
            </div>
          </Reveal>
        ))}
      </div>

      <Reveal className="mt-10 max-w-[60ch] leading-relaxed text-muted">
        <p>
          On Windows and macOS, Brave sells a stripped-down build called Brave Origin. BraveDebloater keeps the Brave
          you have and applies the same class of official policies for free.
        </p>
      </Reveal>
    </section>
  );
}
