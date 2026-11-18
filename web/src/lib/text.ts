const blocks = new Set([
  "P",
  "DIV",
  "SECTION",
  "ARTICLE",
  "HEADER",
  "FOOTER",
  "MAIN",
  "TABLE",
  "TR",
  "UL",
  "OL",
  "BLOCKQUOTE",
  "H1",
  "H2",
  "H3",
  "H4",
  "H5",
  "H6",
  "HR",
  "MJ-SECTION",
  "MJ-COLUMN",
  "MJ-TEXT",
  "MJ-TABLE",
  "MJ-HERO",
  "MJ-WRAPPER",
]);

const skipped = new Set([
  "SCRIPT",
  "STYLE",
  "HEAD",
  "TITLE",
  "TEMPLATE",
  "MJ-HEAD",
  "MJ-STYLE",
  "MJ-ATTRIBUTES",
  "MJ-PREVIEW",
  "MJ-TITLE",
  "MJ-FONT",
  "MJ-BREAKPOINT",
  "MJ-RAW",
]);

function link(element: Element, out: string[]) {
  const before = out.length;
  walk(element, out);
  const label = out.slice(before).join("").trim();
  const target = element.getAttribute("href");
  if (target !== null && target !== "" && target !== label)
    out.push(` (${target})`);
}

function walk(node: Node, out: string[]) {
  for (const child of Array.from(node.childNodes)) {
    if (child.nodeType === Node.TEXT_NODE) {
      out.push((child.textContent ?? "").replace(/\s+/g, " "));
      continue;
    }
    if (!(child instanceof Element)) continue;
    const tag = child.tagName.toUpperCase();
    if (skipped.has(tag)) continue;
    if (tag === "BR") out.push("\n");
    else if (tag === "LI") {
      out.push("\n- ");
      walk(child, out);
    } else if (tag === "A" || tag === "MJ-BUTTON") {
      out.push("\n");
      link(child, out);
      out.push("\n");
    } else if (tag === "TD" || tag === "TH") {
      walk(child, out);
      out.push(" ");
    } else if (blocks.has(tag)) {
      out.push("\n\n");
      walk(child, out);
      out.push("\n\n");
    } else walk(child, out);
  }
}

function tidy(text: string): string {
  return text
    .split("\n")
    .map((line) => line.replace(/[ \t]+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// TP-22
/** A plain-text draft of an e-mail HTML or MJML body: blocks become paragraphs, list items dashes and links "label (address)"; template tags stay as written. */
export function htmlToText(html: string): string {
  const parsed = new DOMParser().parseFromString(html, "text/html");
  const out: string[] = [];
  walk(parsed.body, out);
  return tidy(out.join(""));
}

// TP-10
/** An SMS draft from an e-mail variant: the subject and the first paragraph of the plain text, or of the HTML when the plain text is empty. It is a starting point to edit, never linked to the e-mail. */
export function smsDraftFromEmail(cell: {
  subject: string;
  text: string;
  html: string;
}): string {
  const body = cell.text.trim() === "" ? htmlToText(cell.html) : cell.text;
  const paragraph =
    body
      .split(/\n\s*\n/)
      .map((part) => part.replace(/\s+/g, " ").trim())
      .find((part) => part !== "") ?? "";
  return [cell.subject.replace(/\s+/g, " ").trim(), paragraph]
    .filter((part) => part !== "")
    .join("\n");
}
