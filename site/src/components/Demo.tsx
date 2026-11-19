import { useEffect, useRef, useState } from "react";
import {
  motion,
  useMotionValue,
  useReducedMotion,
  useScroll,
  useTransform,
  type MotionStyle,
  type MotionValue,
} from "motion/react";
import { Pause, Play } from "@phosphor-icons/react";
import { media } from "../lib/links";
import { SectionHeading, cn } from "./ui";

/** Shot boundaries of site/public/media/demo.mp4, the promo cut without its title cards. */
const DURATION = 34.14;
const CHAPTERS = [
  { at: 0, title: "Preview", code: "Invoke-BraveDebloat.ps1", note: "The default run prints the plan and writes nothing." },
  { at: 5.2, title: "Apply", code: "-Apply", note: "The tool saves a backup, then sets the policies." },
  { at: 12.05, title: "Check", code: "brave://policy", note: "After a restart, Brave lists each value." },
  { at: 20.4, title: "Undo", code: "-UndoFromBackup Latest", note: "One command restores the latest backup." },
  { at: 28.74, title: "Report", code: "-ReportPath", note: "The run saves its plan as one HTML file." },
];

function Chapter({
  chapter,
  end,
  time,
  active,
  onSelect,
}: {
  chapter: (typeof CHAPTERS)[number];
  end: number;
  time: MotionValue<number>;
  active: boolean;
  onSelect: () => void;
}) {
  const progress = useTransform(time, [chapter.at, end], [0, 1], { clamp: true });
  return (
    <li className="min-w-[13.5rem] snap-start lg:min-w-0">
      <button
        type="button"
        onClick={onSelect}
        aria-current={active ? "step" : undefined}
        className="group relative block size-full border-t border-line pt-4 pr-4 pb-2 text-left lg:border-t-0 lg:border-l lg:py-0 lg:pr-0 lg:pl-6"
      >
        <motion.span
          aria-hidden
          style={{ "--p": progress } as MotionStyle}
          className="absolute -top-px left-0 h-0.5 w-full origin-left scale-x-(--p) bg-accent lg:top-0 lg:-left-px lg:h-full lg:w-0.5 lg:origin-top lg:scale-x-100 lg:scale-y-(--p)"
        />
        <span
          className={cn(
            "block text-lg font-medium tracking-[-0.01em] transition-colors duration-300",
            active ? "text-text" : "text-muted group-hover:text-text",
          )}
        >
          {chapter.title}
        </span>
        <code
          className={cn(
            "mt-0.5 block text-[0.8125rem] transition-colors duration-300",
            active ? "text-accent-ink" : "text-muted",
          )}
        >
          {chapter.code}
        </code>
        <span className="mt-1.5 block text-sm leading-relaxed text-muted">{chapter.note}</span>
      </button>
    </li>
  );
}

export function Demo() {
  const reduce = useReducedMotion();
  const frame = useRef<HTMLDivElement>(null);
  const video = useRef<HTMLVideoElement>(null);
  const userPaused = useRef(false);
  const time = useMotionValue(0);
  const [active, setActive] = useState(0);
  const [playing, setPlaying] = useState(false);

  const { scrollYProgress } = useScroll({ target: frame, offset: ["start end", "start 0.55"] });
  const scale = useTransform(scrollYProgress, [0, 1], [0.88, 1]);
  const y = useTransform(scrollYProgress, [0, 1], [48, 0]);

  useEffect(() => {
    const el = video.current;
    if (!el) return;
    if (reduce) el.pause();
    let raf = 0;

    const tick = () => {
      time.set(el.currentTime);
      raf = requestAnimationFrame(tick);
    };
    const onPlay = () => {
      setPlaying(true);
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(tick);
    };
    const onPause = () => {
      setPlaying(false);
      cancelAnimationFrame(raf);
    };
    const onTime = () => {
      time.set(el.currentTime);
      let index = 0;
      CHAPTERS.forEach((chapter, i) => {
        if (el.currentTime >= chapter.at) index = i;
      });
      setActive(index);
    };

    el.addEventListener("play", onPlay);
    el.addEventListener("pause", onPause);
    el.addEventListener("timeupdate", onTime);
    el.addEventListener("seeked", onTime);

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry.isIntersecting) el.pause();
        else if (!reduce && !userPaused.current) el.play().catch(() => {});
      },
      { threshold: 0.45 },
    );
    observer.observe(el);

    return () => {
      cancelAnimationFrame(raf);
      observer.disconnect();
      el.removeEventListener("play", onPlay);
      el.removeEventListener("pause", onPause);
      el.removeEventListener("timeupdate", onTime);
      el.removeEventListener("seeked", onTime);
    };
  }, [reduce, time]);

  function toggle() {
    const el = video.current;
    if (!el) return;
    userPaused.current = !el.paused;
    if (el.paused) el.play().catch(() => {});
    else el.pause();
  }

  function seek(at: number) {
    const el = video.current;
    if (!el) return;
    userPaused.current = false;
    el.currentTime = at + 0.04;
    el.play().catch(() => {});
  }

  return (
    <section id="demo" className="py-24 md:py-32">
      <div className="wrap">
        <SectionHeading title="Watch one full run">
          A real run on Linux, cut to 34 seconds: the preview, the apply, the check in brave://policy and the undo.
        </SectionHeading>

        <div className="mt-14 grid grid-cols-1 gap-x-10 gap-y-6 lg:grid-cols-12">
          <motion.div
            ref={frame}
            style={reduce ? undefined : { scale, y }}
            className="origin-top-left overflow-hidden rounded-panel border border-line bg-surface-2 shadow-lift lg:col-span-8"
          >
            <video
              ref={video}
              src={media("demo.mp4")}
              poster={media("demo-poster.webp")}
              muted
              playsInline
              loop
              preload="metadata"
              onClick={toggle}
              aria-label="Screen recording of BraveDebloater on Linux: it previews the Standard preset, applies it, shows the values in brave://policy, then undoes the run."
              className="block aspect-video w-full cursor-pointer"
            />
          </motion.div>

          <ol className="flex snap-x snap-mandatory overflow-x-auto pb-2 [scrollbar-width:thin] lg:col-span-4 lg:grid lg:grid-rows-5 lg:overflow-visible lg:pb-0">
            {CHAPTERS.map((chapter, index) => (
              <Chapter
                key={chapter.title}
                chapter={chapter}
                end={CHAPTERS[index + 1]?.at ?? DURATION}
                time={time}
                active={active === index}
                onSelect={() => seek(chapter.at)}
              />
            ))}
          </ol>

          <div className="lg:col-span-12">
            <button
              type="button"
              onClick={toggle}
              className="inline-flex h-10 items-center gap-2 rounded-ctl border border-line-strong px-3.5 text-sm font-medium transition-[background-color,transform] duration-200 hover:bg-surface-2 active:scale-[0.97]"
            >
              {playing ? <Pause size={16} weight="fill" /> : <Play size={16} weight="fill" />}
              {playing ? "Pause" : "Play"}
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}
