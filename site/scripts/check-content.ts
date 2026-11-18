import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const guarantee =
  "at-least-once delivery with durable idempotency, giving effectively-once processing";
const generated = [
  "reference/api/",
  "reference/events.md",
  "reference/errors.md",
  "reference/limits.md",
];
const skipped = new Set(["node_modules", ".vitepress", "test-results", "playwright-report", "pseudo"]);
const sdkLanguages = new Set([
  "ts",
  "typescript",
  "tsx",
  "js",
  "javascript",
  "jsx",
  "py",
  "python",
  "cs",
  "csharp",
  "java",
  "kt",
  "kotlin",
  "swift",
  "dart",
  "ex",
  "exs",
  "elixir",
  "go",
  "php",
  "rb",
  "ruby",
]);
const runnable = /^examples\/(curl|typescript)\//;
const errors: string[] = [];

function walk(dir: string, found: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (skipped.has(name)) continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path, found);
    else found.push(path);
  }
  return found;
}

const files = walk(site).map((path) => relative(site, path));
const pages = files.filter((file) => file.endsWith(".md") && !generated.some((g) => file.startsWith(g)));
const texts = files.filter((file) => /\.(md|ts|tsx|sh|cs|java|kt|swift|dart|ex|exs|json)$/.test(file));

for (const file of texts) {
  if (file === "scripts/check-content.ts") continue;
  const text = readFileSync(join(site, file), "utf8");
  if (/exactly[- ]once/i.test(text)) errors.push(`${file}: never write "exactly-once"`);
}

const imported = new Set<string>();
for (const page of pages) {
  const text = readFileSync(join(site, page), "utf8");
  if (/§|docs\/spec|\bspec\b/i.test(text)) errors.push(`${page}: refers to a specification`);
  let fence: string | null = null;
  let install = false;
  let body: string[] = [];
  for (const line of text.split("\n")) {
    const open = /^(`{3,})\s*([\w-]*)(.*)$/.exec(line);
    if (fence === null && open) {
      fence = open[2] ?? "";
      install = /\binstall\b/.test(open[3] ?? "");
      body = [];
      continue;
    }
    if (fence !== null && /^`{3,}\s*$/.test(line)) {
      const code = body.join("\n");
      if (sdkLanguages.has(fence) && !install) {
        errors.push(`${page}: inline ${fence} snippet; import it from examples/ so CI runs or compiles it`);
      }
      if (/\bcurl\b/.test(code)) {
        errors.push(`${page}: inline curl command; import it from examples/curl so CI runs it`);
      }
      fence = null;
      continue;
    }
    if (fence !== null) {
      body.push(line);
      continue;
    }
    const snippet = /^<<<\s+@\/(\S+?)(?:#([\w-]+))?(?:\{[^}]*\})?(?:\s.*)?$/.exec(line.trim());
    if (snippet) {
      const [, target = "", region] = snippet;
      imported.add(target);
      const path = join(site, target);
      if (!existsSync(path)) {
        errors.push(`${page}: ${target} does not exist`);
        continue;
      }
      if (region) {
        const source = readFileSync(path, "utf8");
        const start = new RegExp(`^\\s*(?://|#|<!--)\\s*#?region ${region}\\b`, "m");
        if (!start.test(source)) errors.push(`${page}: ${target} has no region ${region}`);
      }
    }
  }
}

for (const file of files) {
  if (!runnable.test(file) || file.endsWith(".run.ts") || file.endsWith("credentials.ts")) continue;
  if (file === "examples/curl/env.sh") continue;
  if (!/\.(sh|ts)$/.test(file)) continue;
  if (!imported.has(file)) errors.push(`${file} is run in CI but no page shows it`);
}

for (const page of ["index.md", "guide/guarantees.md"]) {
  const text = readFileSync(join(site, page), "utf8").replace(/\s+/g, " ");
  if (!text.includes(guarantee)) errors.push(`${page}: must state the guarantee in its exact wording`);
}

const tools = parse(readFileSync(resolve(site, "../contracts/mcp/tools.yaml"), "utf8")) as {
  tools: { name: string }[];
};
const toolNames = new Set(tools.tools.map((tool) => tool.name));
const skills = files.filter((file) => file.startsWith("skills/") && file.endsWith("SKILL.md"));
if (skills.length === 0) errors.push("skills/: no skill files");
for (const skill of skills) {
  const text = readFileSync(join(site, skill), "utf8");
  const front = /^---\n([\s\S]*?)\n---\n/.exec(text);
  const meta = front ? (parse(front[1] ?? "") as Record<string, unknown>) : {};
  if (typeof meta["name"] !== "string" || typeof meta["description"] !== "string") {
    errors.push(`${skill}: frontmatter needs name and description`);
  } else if (meta["name"] !== skill.split("/")[1]) {
    errors.push(`${skill}: name must equal its folder name`);
  }
  for (const match of text.matchAll(/\brelay_[a-z_]+\b/g)) {
    if (!toolNames.has(match[0])) errors.push(`${skill}: ${match[0]} is not an MCP tool of Relay`);
  }
}

if (errors.length > 0) {
  for (const error of errors) console.error(error);
  process.exit(1);
}
console.log(`content: ${pages.length} pages, ${imported.size} imported examples, ${skills.length} skills`);
