import { readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

const dist = resolve(dirname(fileURLToPath(import.meta.url)), "../.vitepress/dist");
const tags = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];

function walk(dir: string, found: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path, found);
    else if (name.endsWith(".html")) found.push(path);
  }
  return found;
}

const pages = walk(dist).map((path) => `/${relative(dist, path).split("\\").join("/")}`);

for (const scheme of ["light", "dark"] as const) {
  for (const page of pages) {
    test(`WCAG 2.2 AA ${scheme} ${page}`, async ({ page: browser }) => {
      await browser.emulateMedia({ colorScheme: scheme });
      await browser.goto(page);
      await browser.waitForLoadState("networkidle");
      const results = await new AxeBuilder({ page: browser }).withTags(tags).analyze();
      const summary = results.violations.map(
        (violation) =>
          `${violation.id}: ${violation.help} (${violation.nodes
            .slice(0, 5)
            .map((node) => node.target.join(" "))
            .join(", ")})`,
      );
      expect(summary).toEqual([]);
    });
  }
}
