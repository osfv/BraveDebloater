import { motion } from "motion/react";
import { ArrowDown, GithubLogo } from "@phosphor-icons/react";
import { REPO } from "../lib/links";
import { Compare } from "./Compare";
import { EASE } from "./ui";

const LINES = ["Keep Brave.", "Lose the extras."];

export function Hero() {
  return (
    <section id="top" className="relative">
      <div className="wrap grid grid-cols-1 items-center gap-12 pt-24 pb-16 lg:min-h-[100dvh] lg:grid-cols-12 lg:gap-10 lg:pb-12">
        <div className="lg:col-span-7">
          <h1 className="text-[clamp(2.5rem,6.3vw,5.25rem)] leading-[1] font-semibold tracking-[-0.045em]">
            {LINES.map((line, index) => (
              <span key={line} className="-mb-[0.1em] block overflow-hidden pb-[0.14em]">
                <motion.span
                  className="block"
                  initial={{ y: "112%" }}
                  animate={{ y: 0 }}
                  transition={{ duration: 1, delay: 0.15 + index * 0.11, ease: EASE }}
                >
                  {line}
                </motion.span>
              </span>
            ))}
          </h1>
          <motion.p
            className="mt-7 max-w-[33rem] text-lg leading-relaxed text-muted md:text-xl md:leading-relaxed"
            initial={{ opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.8, delay: 0.5, ease: EASE }}
          >
            Turn off Rewards, Wallet, VPN, Leo and telemetry with Brave's own enterprise policies. Preview first, undo
            from a backup.
          </motion.p>
          <motion.div
            className="mt-9 flex flex-wrap gap-3"
            initial={{ opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.8, delay: 0.62, ease: EASE }}
          >
            <a
              href="#install"
              className="group inline-flex h-12 items-center gap-2.5 rounded-ctl bg-accent px-6 font-medium text-on-accent transition-[filter,transform] duration-200 hover:brightness-110 active:scale-[0.98]"
            >
              Install
              <ArrowDown
                size={18}
                weight="bold"
                className="transition-transform duration-300 ease-out-expo group-hover:translate-y-0.5"
              />
            </a>
            <a
              href={REPO}
              className="inline-flex h-12 items-center gap-2.5 rounded-ctl border border-line-strong px-6 font-medium transition-[background-color,transform] duration-200 hover:bg-surface-2 active:scale-[0.98]"
            >
              <GithubLogo size={19} />
              View on GitHub
            </a>
          </motion.div>
        </div>
        <motion.div
          className="flex justify-center lg:col-span-5 lg:justify-end"
          initial={{ opacity: 0, y: 36, scale: 0.97 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ duration: 1.1, delay: 0.3, ease: EASE }}
        >
          <Compare />
        </motion.div>
      </div>
    </section>
  );
}
