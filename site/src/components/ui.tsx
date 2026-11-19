import { useEffect, useRef, useState, type ReactNode } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Check, Copy } from "@phosphor-icons/react";

export const cn = (...parts: (string | false | null | undefined)[]) => parts.filter(Boolean).join(" ");

export const EASE = [0.16, 1, 0.3, 1] as const;

export function Reveal({
  children,
  delay = 0,
  className,
}: {
  children: ReactNode;
  delay?: number;
  className?: string;
}) {
  return (
    <motion.div
      className={className}
      initial={{ opacity: 0, y: 28 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.2 }}
      transition={{ duration: 0.8, delay, ease: EASE }}
    >
      {children}
    </motion.div>
  );
}

export function SectionHeading({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <Reveal className="max-w-[44rem]">
      <h2 className="text-[clamp(2rem,4.2vw,3.25rem)] font-semibold leading-[1.04] tracking-[-0.035em] text-balance">
        {title}
      </h2>
      {children && <p className="mt-5 max-w-[60ch] text-lg leading-relaxed text-muted text-pretty">{children}</p>}
    </Reveal>
  );
}

type CopyState = "idle" | "copied" | "failed";

export function CopyButton({
  text,
  label = "Copy",
  disabled,
  variant = "quiet",
  className,
}: {
  text: string;
  label?: string;
  disabled?: boolean;
  variant?: "quiet" | "solid";
  className?: string;
}) {
  const [state, setState] = useState<CopyState>("idle");
  const timer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(timer.current), []);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setState("copied");
    } catch {
      setState("failed");
    }
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setState("idle"), 2000);
  }

  return (
    <button
      type="button"
      onClick={copy}
      disabled={disabled}
      className={cn(
        "inline-flex h-10 shrink-0 items-center gap-2 rounded-ctl px-3.5 text-sm font-medium whitespace-nowrap transition-[background-color,border-color,transform,opacity] duration-200 active:scale-[0.97] disabled:pointer-events-none disabled:opacity-40",
        variant === "solid"
          ? "bg-accent text-on-accent hover:brightness-110"
          : "border border-line-strong text-text hover:bg-surface-2",
        className,
      )}
    >
      <span className="relative grid size-4 place-items-center">
        <AnimatePresence mode="wait" initial={false}>
          <motion.span
            key={state === "copied" ? "done" : "copy"}
            className="absolute inset-0 grid place-items-center"
            initial={{ scale: 0.4, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            exit={{ scale: 0.4, opacity: 0 }}
            transition={{ duration: 0.16 }}
          >
            {state === "copied" ? <Check size={16} weight="bold" /> : <Copy size={16} />}
          </motion.span>
        </AnimatePresence>
      </span>
      <span aria-live="polite">{state === "copied" ? "Copied" : state === "failed" ? "Select it and copy" : label}</span>
    </button>
  );
}

export function CommandLine({ text, label, large }: { text: string; label: string; large?: boolean }) {
  return (
    <div
      className={cn(
        "flex items-center gap-3 rounded-ctl border border-line bg-surface-2",
        large ? "py-2.5 pr-2.5 pl-5" : "py-2 pr-2 pl-4",
      )}
    >
      <code
        aria-label={label}
        tabIndex={0}
        className={cn(
          "min-w-0 flex-1 overflow-x-auto py-2 whitespace-nowrap text-text [scrollbar-width:thin]",
          large ? "text-[0.9375rem] max-sm:break-all max-sm:whitespace-normal" : "text-[0.875rem]",
        )}
      >
        {text}
      </code>
      <CopyButton text={text} variant={large ? "solid" : "quiet"} />
    </div>
  );
}
