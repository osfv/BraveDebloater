import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { GithubLogo, Moon, Sun } from "@phosphor-icons/react";
import { REPO, media } from "../lib/links";
import { EASE, cn } from "./ui";

const LINKS = [
  { href: "#features", label: "Features" },
  { href: "#demo", label: "Demo" },
  { href: "#safety", label: "Safety" },
];

function ThemeToggle() {
  const [dark, setDark] = useState(() => document.documentElement.dataset.theme === "dark");

  function toggle() {
    const next = !dark;
    setDark(next);
    document.documentElement.dataset.theme = next ? "dark" : "light";
    try {
      localStorage.setItem("theme", next ? "dark" : "light");
    } catch {
      /* private mode: the choice lasts for this visit only */
    }
  }

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={dark ? "Switch to the light theme" : "Switch to the dark theme"}
      className="relative grid size-10 place-items-center overflow-hidden rounded-ctl text-muted transition-colors duration-200 hover:bg-surface-2 hover:text-text active:scale-[0.96]"
    >
      <AnimatePresence mode="wait" initial={false}>
        <motion.span
          key={dark ? "moon" : "sun"}
          initial={{ y: 14, opacity: 0, rotate: -40 }}
          animate={{ y: 0, opacity: 1, rotate: 0 }}
          exit={{ y: -14, opacity: 0, rotate: 40 }}
          transition={{ duration: 0.22, ease: EASE }}
        >
          {dark ? <Moon size={19} /> : <Sun size={19} />}
        </motion.span>
      </AnimatePresence>
    </button>
  );
}

export function Nav() {
  const sentinel = useRef<HTMLDivElement>(null);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const node = sentinel.current;
    if (!node) return;
    const observer = new IntersectionObserver(([entry]) => setScrolled(!entry.isIntersecting));
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  return (
    <>
      <div ref={sentinel} aria-hidden className="pointer-events-none absolute top-0 h-6 w-px" />
      <a
        href="#main"
        className="fixed top-3 left-3 z-(--z-skip) -translate-y-20 rounded-ctl bg-accent px-4 py-2 text-sm font-medium text-on-accent focus:translate-y-0"
      >
        Skip to content
      </a>
      <motion.header
        initial={{ y: -24, opacity: 0 }}
        animate={{ y: 0, opacity: 1 }}
        transition={{ duration: 0.7, ease: EASE }}
        className={cn(
          "fixed inset-x-0 top-0 z-(--z-nav) border-b transition-[background-color,border-color,backdrop-filter] duration-300",
          scrolled ? "border-line bg-bg/80 backdrop-blur-lg" : "border-transparent",
        )}
      >
        <nav aria-label="Main" className="wrap flex h-16 items-center justify-between gap-4">
          <a href="#top" className="group flex items-center gap-2.5 font-semibold tracking-[-0.02em]">
            <img
              src={media("logo.webp")}
              alt=""
              width={30}
              height={30}
              className="size-[30px] transition-transform duration-500 ease-out-expo group-hover:-rotate-12"
            />
            BraveDebloater
          </a>
          <div className="flex items-center gap-1">
            <ul className="mr-2 hidden items-center md:flex">
              {LINKS.map((link) => (
                <li key={link.href}>
                  <a
                    href={link.href}
                    className="rounded-ctl px-3 py-2 text-[0.9375rem] text-muted transition-colors duration-200 hover:text-text"
                  >
                    {link.label}
                  </a>
                </li>
              ))}
            </ul>
            <a
              href={REPO}
              aria-label="View on GitHub"
              className="grid size-10 place-items-center rounded-ctl text-muted transition-colors duration-200 hover:bg-surface-2 hover:text-text active:scale-[0.96]"
            >
              <GithubLogo size={19} />
            </a>
            <ThemeToggle />
            <a
              href="#install"
              className="ml-2 inline-flex h-10 items-center rounded-ctl bg-accent px-4 text-[0.9375rem] font-medium text-on-accent transition-[filter,transform] duration-200 hover:brightness-110 active:scale-[0.97]"
            >
              Install
            </a>
          </div>
        </nav>
      </motion.header>
    </>
  );
}
