import { useEffect, useRef, type PointerEvent } from "react";
import {
  animate,
  motion,
  useMotionTemplate,
  useMotionValue,
  useMotionValueEvent,
  useReducedMotion,
  type AnimationPlaybackControls,
} from "motion/react";
import { Broom } from "@phosphor-icons/react";
import { media } from "../lib/links";

const clamp = (value: number) => Math.min(100, Math.max(0, value));

/**
 * Two frames from the Linux recording in assets/videos: the browser after
 * `-Preset Standard -Apply`, and the same window after the undo run (stock Brave).
 * The broom handle wipes the stock frame away once, then follows the pointer.
 */
export function Compare() {
  const reduce = useReducedMotion();
  const box = useRef<HTMLDivElement>(null);
  const range = useRef<HTMLInputElement>(null);
  const dragging = useRef(false);
  const sweep = useRef<AnimationPlaybackControls | null>(null);

  const pos = useMotionValue(reduce ? 50 : 0);
  const clip = useMotionTemplate`inset(0 0 0 ${pos}%)`;
  const x = useMotionTemplate`${pos}%`;

  useEffect(() => {
    if (reduce) return;
    sweep.current = animate(pos, 100, { duration: 2.1, delay: 1.15, ease: [0.65, 0, 0.35, 1] });
    return () => sweep.current?.stop();
  }, [pos, reduce]);

  useMotionValueEvent(pos, "change", (value) => {
    if (range.current) range.current.value = String(Math.round(value));
  });

  function moveTo(event: PointerEvent<HTMLDivElement>) {
    const rect = box.current?.getBoundingClientRect();
    if (!rect) return;
    pos.set(clamp(((event.clientX - rect.left) / rect.width) * 100));
  }

  return (
    <figure className="compare-box">
      <div
        ref={box}
        className="relative w-full cursor-ew-resize touch-pan-y select-none"
        onPointerDown={(event) => {
          sweep.current?.stop();
          dragging.current = true;
          event.currentTarget.setPointerCapture(event.pointerId);
          moveTo(event);
        }}
        onPointerMove={(event) => dragging.current && moveTo(event)}
        onPointerUp={() => (dragging.current = false)}
        onPointerCancel={() => (dragging.current = false)}
      >
        <div className="absolute inset-0 overflow-hidden rounded-panel border border-line bg-surface-2 shadow-lift">
          <img
            src={media("brave-after.webp")}
            alt="Brave after the Standard preset. The toolbar keeps the Shields, sidebar and menu buttons, and the new tab page shows only the stats card."
            width={842}
            height={992}
            draggable={false}
            className="absolute inset-0 size-full object-cover"
          />
          <motion.img
            src={media("brave-stock.webp")}
            alt="Stock Brave. The toolbar also carries Rewards, Wallet and Leo buttons, and a Rewards card sits under the stats."
            width={842}
            height={992}
            draggable={false}
            fetchPriority="high"
            style={{ clipPath: clip }}
            className="absolute inset-0 size-full object-cover"
          />
        </div>

        <input
          ref={range}
          type="range"
          min={0}
          max={100}
          step={2}
          defaultValue={reduce ? 50 : 0}
          aria-label="Wipe from stock Brave to the cleaned-up browser"
          className="peer sr-only"
          onChange={(event) => {
            sweep.current?.stop();
            pos.set(Number(event.target.value));
          }}
        />

        <div aria-hidden className="pointer-events-none absolute inset-y-0 -inset-x-5 overflow-clip sm:-inset-x-7 peer-focus-visible:[&_[data-knob]]:outline-2">
          <motion.div style={{ x }} className="absolute inset-x-5 inset-y-0 sm:inset-x-7">
            <span className="absolute inset-y-0 left-0 w-0.5 -translate-x-1/2 bg-[#f6f6f7] shadow-[0_0_0_1px_rgb(0_0_0/0.18),0_0_18px_rgb(0_0_0/0.35)]" />
            <span
              data-knob
              className="absolute top-[56%] left-0 grid size-10 -translate-x-1/2 sm:size-12 -translate-y-1/2 place-items-center rounded-ctl bg-accent text-on-accent shadow-[0_8px_24px_-6px_rgb(0_0_0/0.55)] outline-offset-4 outline-accent-ink"
            >
              <Broom size={24} weight="fill" />
            </span>
          </motion.div>
        </div>
      </div>
      <figcaption className="mt-3 flex justify-between gap-4 text-sm text-muted">
        <span>After the Standard preset</span>
        <span>Stock Brave</span>
      </figcaption>
    </figure>
  );
}
