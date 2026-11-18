import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

type Messages = Record<string, string>;

interface Catalog {
  name: string;
  dir: string;
  base: string;
}

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repo = resolve(site, "..");
const pseudoDir = join(site, "pseudo");

const catalogs: Catalog[] = [
  { name: "console", dir: join(repo, "web/src/i18n"), base: "en" },
  { name: "site", dir: join(site, ".vitepress/i18n"), base: "en" },
].filter((catalog) => existsSync(join(catalog.dir, `${catalog.base}.ts`)));

async function load(file: string): Promise<Messages> {
  const source = readFileSync(file, "utf8");
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const loaded = (await import(
    `data:text/javascript;base64,${Buffer.from(output).toString("base64")}`
  )) as Record<string, unknown>;
  const name = basename(file, ".ts");
  const value = loaded[name] ?? loaded["default"] ?? Object.values(loaded)[0];
  if (typeof value !== "object" || value === null) throw new Error(`${file} exports no catalog`);
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>).map(([key, text]) => [key, String(text)]),
  );
}

function placeholders(text: string): string[] {
  return [...text.matchAll(/\{\s*([A-Za-z_][\w.]*)[^{}]*\}/g)].map((m) => m[1] ?? "").sort();
}

const accents: Record<string, string> = {
  a: "á",
  c: "ç",
  e: "é",
  g: "ğ",
  i: "í",
  n: "ñ",
  o: "ö",
  s: "ş",
  u: "ü",
  y: "ý",
  A: "Á",
  C: "Ç",
  E: "É",
  G: "Ğ",
  I: "İ",
  N: "Ñ",
  O: "Ö",
  S: "Ş",
  U: "Ü",
  Y: "Ý",
};

function pseudo(text: string): string {
  const parts = text.split(/(\{[^{}]*\})/g);
  const body = parts
    .map((part) => (part.startsWith("{") ? part : [...part].map((c) => accents[c] ?? c).join("")))
    .join("");
  const padding = "~".repeat(Math.ceil(text.length * 0.35));
  return `⟦${body}${padding}⟧`;
}

const errors: string[] = [];
let checked = 0;
mkdirSync(pseudoDir, { recursive: true });

for (const catalog of catalogs) {
  const base = await load(join(catalog.dir, `${catalog.base}.ts`));
  const keys = Object.keys(base).sort();
  const where = relative(repo, catalog.dir);
  for (const key of keys) {
    if ((base[key] ?? "").trim() === "") errors.push(`${where}/${catalog.base}: ${key} is empty`);
  }
  const locales = readdirSync(catalog.dir)
    .filter((file) => /^[a-z]{2}(?:-[A-Z]{2})?\.ts$/.test(file) && file !== `${catalog.base}.ts`)
    .map((file) => basename(file, ".ts"));
  for (const locale of locales) {
    const messages = await load(join(catalog.dir, `${locale}.ts`));
    for (const key of keys) {
      const text = messages[key];
      if (text === undefined) {
        errors.push(`${where}/${locale}: missing translation of ${key}`);
        continue;
      }
      if (text.trim() === "") errors.push(`${where}/${locale}: ${key} is empty`);
      const expected = placeholders(base[key] ?? "").join(",");
      const actual = placeholders(text).join(",");
      if (expected !== actual) {
        errors.push(
          `${where}/${locale}: ${key} has placeholders {${actual}}, expected {${expected}}`,
        );
      }
    }
    for (const key of Object.keys(messages)) {
      if (!(key in base)) errors.push(`${where}/${locale}: ${key} is not in ${catalog.base}`);
    }
  }
  const pseudoMessages: Messages = {};
  for (const key of keys) {
    const text = base[key] ?? "";
    const result = pseudo(text);
    if (placeholders(result).join(",") !== placeholders(text).join(",")) {
      errors.push(`${where}: pseudo-localisation breaks the placeholders of ${key}`);
    }
    pseudoMessages[key] = result;
  }
  writeFileSync(
    join(pseudoDir, `${catalog.name}.json`),
    `${JSON.stringify(pseudoMessages, null, 2)}\n`,
  );
  checked += keys.length;
  console.log(
    `${catalog.name}: ${keys.length} texts, locales ${[catalog.base, ...locales].join(", ")}`,
  );
}

if (catalogs.length === 0) errors.push("no text catalog found");
if (errors.length > 0) {
  for (const error of errors) console.error(error);
  process.exit(1);
}
console.log(`translations: ${checked} texts checked; pseudo-locales written to pseudo/`);
