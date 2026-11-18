import type { ServerSchemas } from "../../api/types";

export type Cells = ServerSchemas["TemplateCells"];
export type CellChannel = keyof Cells;
export type Cell = Record<string, unknown>;

export const cellChannels: readonly CellChannel[] = [
  "email",
  "sms",
  "push",
  "web_push",
  "in_app",
  "whatsapp",
  "voice",
  "webhook",
];

export interface CellField {
  name: string;
  multiline: boolean;
  required: boolean;
}

const field = (
  name: string,
  multiline = false,
  required = true,
): CellField => ({
  name,
  multiline,
  required,
});

const push = [
  field("title"),
  field("subtitle", false, false),
  field("body", true),
  field("lock_screen_body", true, false),
  field("in_app_body", true, false),
];

// TP-10
/** The text fields of a channel variant, as the template schema defines them. */
export const cellFields: Record<CellChannel, readonly CellField[]> = {
  sms: [field("body", true)],
  push,
  web_push: push,
  email: [
    field("subject"),
    field("preheader", false, false),
    field("html", true),
    field("text", true),
  ],
  whatsapp: [field("template_name"), field("language", false, false)],
  in_app: [
    field("title"),
    field("body", true),
    field("avatar_url", false, false),
  ],
  webhook: [field("body", true)],
  voice: [field("body", true)],
};

export function emptyCell(channel: CellChannel): Cell {
  switch (channel) {
    case "email":
      return { subject: "", html_kind: "mjml", html: "", text: "" };
    case "push":
    case "web_push":
      return { title: "", body: "" };
    case "whatsapp":
      return { template_name: "", parameters: [] };
    case "in_app":
      return { title: "", body: "" };
    case "sms":
    case "webhook":
    case "voice":
      return { body: "" };
  }
}

export function cellsOf(
  cells: Cells,
  channel: CellChannel,
): Record<string, Cell> {
  return cells[channel] ?? {};
}

export function getCell(
  cells: Cells,
  channel: CellChannel,
  locale: string,
): Cell | null {
  return cellsOf(cells, channel)[locale] ?? null;
}

export function setCell(
  cells: Cells,
  channel: CellChannel,
  locale: string,
  cell: Cell | null,
): Cells {
  const current = cellsOf(cells, channel);
  const next = Object.fromEntries(
    Object.entries(current).filter(([name]) => name !== locale),
  );
  if (cell !== null) next[locale] = cell;
  const rest = Object.fromEntries(
    Object.entries(cells).filter(([name]) => name !== channel),
  ) as Cells;
  return Object.keys(next).length === 0
    ? rest
    : { ...rest, [channel]: next };
}

export function cellText(cell: Cell, name: string): string {
  const value = cell[name];
  return typeof value === "string" ? value : "";
}

export function locales(defaultLocale: string, cells: Cells): string[] {
  const found = new Set<string>([defaultLocale]);
  for (const channel of cellChannels)
    for (const locale of Object.keys(cellsOf(cells, channel)))
      found.add(locale);
  return [...found];
}

export const localePattern = /^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/;
