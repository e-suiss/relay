import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(site, ".vitepress", "dist");

function walk(dir: string, found: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path, found);
    else if (name.endsWith(".html")) found.push(path);
  }
  return found;
}

function decode(text: string): string {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

if (!existsSync(dist)) {
  console.error("run `npm run build` first");
  process.exit(1);
}

const pages = walk(dist);
const ids = new Map<string, Set<string>>();
for (const page of pages) {
  const html = readFileSync(page, "utf8");
  ids.set(page, new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => decode(m[1] ?? ""))));
}

const errors: string[] = [];
let checked = 0;
for (const page of pages) {
  const html = readFileSync(page, "utf8");
  for (const match of html.matchAll(/\shref="([^"]*)"/g)) {
    const href = decode(match[1] ?? "");
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(href) || href === "") continue;
    checked++;
    const [pathPart = "", anchor] = href.split("#");
    let target = page;
    if (pathPart !== "") {
      const clean = pathPart.split("?")[0] ?? "";
      const base = clean.startsWith("/") ? join(dist, clean) : resolve(dirname(page), clean);
      const candidates = [base, join(base, "index.html"), `${base}.html`];
      const found = candidates.find(
        (candidate) => existsSync(candidate) && statSync(candidate).isFile(),
      );
      if (!found) {
        errors.push(`${relative(dist, page)}: broken link ${href}`);
        continue;
      }
      target = found;
    }
    if (anchor && target.endsWith(".html")) {
      const targetIds = ids.get(target);
      if (targetIds && !targetIds.has(decodeURIComponent(anchor))) {
        errors.push(`${relative(dist, page)}: missing anchor ${href}`);
      }
    }
  }
}

if (errors.length > 0) {
  for (const error of errors) console.error(error);
  process.exit(1);
}
console.log(`links: ${checked} internal links in ${pages.length} pages resolve`);
