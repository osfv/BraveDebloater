import { RELEASES, REPO, media } from "../lib/links";

const LINKS = [
  { href: REPO, label: "GitHub" },
  { href: RELEASES, label: "Releases" },
  { href: REPO + "/blob/main/CHANGELOG.md", label: "Changelog" },
  { href: REPO + "/blob/main/SECURITY.md", label: "Security" },
  { href: REPO + "/blob/main/LICENSE", label: "License" },
];

export function Footer() {
  return (
    <footer className="wrap py-12">
      <div className="flex flex-col gap-8 md:flex-row md:items-start md:justify-between">
        <div className="max-w-[30rem]">
          <p className="flex items-center gap-2.5 font-semibold tracking-[-0.02em]">
            <img src={media("logo.webp")} alt="" width={30} height={30} loading="lazy" className="size-[30px]" />
            BraveDebloater
          </p>
          <p className="mt-4 text-sm leading-relaxed text-muted">
            An independent open source project under the MIT license. Brave Software does not endorse it and has no
            affiliation with it.
          </p>
        </div>
        <ul className="flex flex-wrap gap-x-7 gap-y-3 text-[0.9375rem]">
          {LINKS.map((link) => (
            <li key={link.label}>
              <a href={link.href} className="text-muted transition-colors duration-200 hover:text-text">
                {link.label}
              </a>
            </li>
          ))}
        </ul>
      </div>
    </footer>
  );
}
