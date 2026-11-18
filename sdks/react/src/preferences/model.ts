import type { ConsentView } from "../seams.js";

/** A stored preference value (PC-13). */
export type PreferenceValue = "opt_in" | "opt_out" | "unset";

/** One weekly time range (§13.4.1). */
export interface TimeRange {
  readonly day: "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun";
  readonly start: string;
  readonly end: string;
}

/** The subscriber's delivery profile. */
export interface PreferenceProfile {
  readonly quiet_hours: readonly TimeRange[];
  readonly schedule: readonly TimeRange[];
  readonly dnd_until: string | null;
  readonly quiet_hours_email: boolean;
  readonly digest: Readonly<Record<string, "instant" | "digest">>;
}

/** One category × channel cell as the components render it (X-51). */
export interface PreferenceCellView {
  readonly category: string;
  readonly category_name: string;
  readonly channel: string;
  readonly value: PreferenceValue;
  readonly effective: boolean;
  readonly source: string;
  readonly locked: boolean;
  readonly lock_beneficiary: "subscriber" | "tenant" | null;
  readonly digest_allowed: boolean;
  readonly disabled_by_admin: boolean;
  readonly disabled_in_device_settings: boolean;
  readonly message_class: string | null;
}

/** The subscriber's preferences as the components render them. */
export interface PreferencesView {
  readonly subscriber_id: string;
  readonly cells: readonly PreferenceCellView[];
  readonly channels: readonly { readonly channel: string; readonly value: PreferenceValue }[];
  readonly workflows: readonly { readonly workflow: string; readonly value: PreferenceValue }[];
  readonly scope_keys: readonly { readonly scope_key: string; readonly value: PreferenceValue }[];
  readonly profile: PreferenceProfile;
}

/** One preference write (PC-57). */
export interface PreferenceWrite {
  readonly level: "category_channel" | "channel" | "workflow" | "scope_key";
  readonly category?: string;
  readonly channel?: string;
  readonly workflow?: string;
  readonly scope_key?: string;
  readonly value: PreferenceValue;
}

/** The body of a preference update. */
export interface PreferencesPatch {
  readonly preferences?: readonly PreferenceWrite[];
  readonly profile?: Partial<PreferenceProfile>;
}

function bool(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function value(raw: unknown): PreferenceValue {
  return raw === "opt_in" || raw === "opt_out" ? raw : "unset";
}

/**
 * Reads a cell. The lock beneficiary, the administrator's and the device settings' states and the digest choice come from the cell when the server sends them (X-51); before that the lock and the administrator's state are taken from `source`.
 */
export function normaliseCell(
  raw: Record<string, unknown>,
  digest: PreferenceProfile["digest"],
): PreferenceCellView {
  const category = String(raw.category);
  const source = typeof raw.source === "string" ? raw.source : "class_default";
  const effective = bool(raw.effective, false);
  const beneficiary = raw.lock_beneficiary;
  return {
    category,
    category_name:
      typeof raw.category_name === "string" && raw.category_name.length > 0
        ? raw.category_name
        : category,
    channel: String(raw.channel),
    value: value(raw.value),
    effective,
    source,
    locked: bool(raw.locked, source === "locked"),
    lock_beneficiary: beneficiary === "subscriber" || beneficiary === "tenant" ? beneficiary : null,
    digest_allowed: bool(raw.digest_allowed, digest[category] !== undefined),
    disabled_by_admin: bool(raw.disabled_by_admin, source === "tenant" && !effective),
    disabled_in_device_settings: bool(raw.disabled_in_device_settings, false),
    message_class: typeof raw.message_class === "string" ? raw.message_class : null,
  };
}

/** Reads the preferences answer of the subscriber API. */
export function normalisePreferences(raw: unknown): PreferencesView {
  const record = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const profileRaw = (
    typeof record.profile === "object" && record.profile !== null ? record.profile : {}
  ) as Record<string, unknown>;
  const digest = (
    typeof profileRaw.digest === "object" && profileRaw.digest !== null ? profileRaw.digest : {}
  ) as Record<string, "instant" | "digest">;
  const profile: PreferenceProfile = {
    quiet_hours: Array.isArray(profileRaw.quiet_hours)
      ? (profileRaw.quiet_hours as TimeRange[])
      : [],
    schedule: Array.isArray(profileRaw.schedule) ? (profileRaw.schedule as TimeRange[]) : [],
    dnd_until: typeof profileRaw.dnd_until === "string" ? profileRaw.dnd_until : null,
    quiet_hours_email: bool(profileRaw.quiet_hours_email, false),
    digest,
  };
  const list = (key: string) =>
    Array.isArray(record[key]) ? (record[key] as Record<string, unknown>[]) : [];
  return {
    subscriber_id: typeof record.subscriber_id === "string" ? record.subscriber_id : "",
    cells: list("cells").map((cell) => normaliseCell(cell, digest)),
    channels: list("channels").map((entry) => ({
      channel: String(entry.channel),
      value: value(entry.value),
    })),
    workflows: list("workflows").map((entry) => ({
      workflow: String(entry.workflow),
      value: value(entry.value),
    })),
    scope_keys: list("scope_keys").map((entry) => ({
      scope_key: String(entry.scope_key),
      value: value(entry.value),
    })),
    profile,
  };
}

const followers: ReadonlySet<string> = new Set(["web_push", "voice"]);

/** The channel columns in the order the cells name them; web push follows push and voice follows SMS, so they get no column. */
export function channelColumns(view: PreferencesView): string[] {
  const columns: string[] = [];
  for (const cell of view.cells) {
    if (!followers.has(cell.channel) && !columns.includes(cell.channel)) columns.push(cell.channel);
  }
  return columns;
}

/** One category row of the matrix. */
export interface CategoryRow {
  readonly category: string;
  readonly name: string;
  readonly locked: boolean;
  readonly beneficiary: "subscriber" | "tenant" | null;
  readonly marketing: boolean;
}

/** The category rows in the order the cells name them. */
export function categoryRows(
  view: PreferencesView,
  marketingCategories: ReadonlySet<string> = new Set(),
): CategoryRow[] {
  const rows = new Map<string, CategoryRow>();
  for (const cell of view.cells) {
    const known = rows.get(cell.category);
    rows.set(cell.category, {
      category: cell.category,
      name: cell.category_name,
      locked: (known?.locked ?? false) || cell.locked,
      beneficiary: known?.beneficiary ?? cell.lock_beneficiary,
      marketing:
        (known?.marketing ?? false) ||
        cell.message_class === "marketing" ||
        marketingCategories.has(cell.category),
    });
  }
  return [...rows.values()];
}

/** The cell of a category and channel, if the subscriber has one. */
export function cellOf(
  view: PreferencesView,
  category: string,
  channel: string,
): PreferenceCellView | undefined {
  return view.cells.find((cell) => cell.category === category && cell.channel === channel);
}

/** How a cell is shown (§13.4.4, PC-6, PC-15, PC-16, X-51). */
export type CellState =
  | { readonly kind: "unavailable" }
  | { readonly kind: "locked"; readonly on: boolean }
  | { readonly kind: "admin_off" }
  | { readonly kind: "permission_pending" }
  | {
      readonly kind: "switch";
      readonly on: boolean;
      readonly deviceOff: boolean;
      readonly digestAllowed: boolean;
    };

/**
 * The state of a cell: `—` when the subscriber has no such cell, a label for a locked cell ("On (locked)") and for one the administrator turned off, "Permission pending · Allow" on a marketing row whose channel has no active consent, and a switch otherwise, noting when the device settings turn it off.
 */
export function cellState(
  cell: PreferenceCellView | undefined,
  context: { readonly marketing: boolean; readonly consents: readonly ConsentView[] | null },
): CellState {
  if (cell === undefined) return { kind: "unavailable" };
  if (cell.locked) return { kind: "locked", on: cell.effective };
  if (cell.disabled_by_admin) return { kind: "admin_off" };
  if (context.marketing && context.consents !== null) {
    const consent = context.consents.find((entry) => entry.channel === cell.channel);
    if (consent === undefined || consent.status !== "active") return { kind: "permission_pending" };
  }
  return {
    kind: "switch",
    on: cell.value === "opt_out" ? false : cell.value === "opt_in" ? true : cell.effective,
    deviceOff: cell.disabled_in_device_settings,
    digestAllowed: cell.digest_allowed,
  };
}

/** Whether turning a cell off asks Instant / Digest / Never first (PC-17). */
export function needsDigestStep(state: CellState): boolean {
  return state.kind === "switch" && state.on && state.digestAllowed;
}

/** The writes of a switch: on is the subscriber's own opt-in, off its opt-out (PC-57). */
export function cellWrite(
  cell: Pick<PreferenceCellView, "category" | "channel">,
  on: boolean,
): PreferencesPatch {
  return {
    preferences: [
      {
        level: "category_channel",
        category: cell.category,
        channel: cell.channel,
        value: on ? "opt_in" : "opt_out",
      },
    ],
  };
}

/** The three choices of the step (PC-17); none is preselected. */
export type DigestChoice = "instant" | "digest" | "never";

/** The writes of a step choice: Instant or Digest keeps the cell on with that digest choice, Never turns it off. */
export function digestChoiceWrite(
  cell: Pick<PreferenceCellView, "category" | "channel">,
  choice: DigestChoice,
  digest: PreferenceProfile["digest"],
): PreferencesPatch {
  if (choice === "never") return cellWrite(cell, false);
  return { profile: { digest: { ...digest, [cell.category]: choice } } };
}

/** The writes that turn every switchable, open cell of a category off (X-22): locked and administrator cells stay. */
export function rowOffWrite(
  view: PreferencesView,
  row: CategoryRow,
  consents: readonly ConsentView[] | null,
): PreferencesPatch | null {
  const preferences = view.cells
    .filter((cell) => cell.category === row.category)
    .filter((cell) => {
      const state = cellState(cell, { marketing: row.marketing, consents });
      return state.kind === "switch" && state.on;
    })
    .map((cell): PreferenceWrite => ({
      level: "category_channel",
      category: cell.category,
      channel: cell.channel,
      value: "opt_out",
    }));
  return preferences.length === 0 ? null : { preferences };
}

/** The write of a global channel switch (§13.4.1): a preference across categories, not a withdrawal of consent. */
export function channelWrite(channel: string, on: boolean): PreferencesPatch {
  return { preferences: [{ level: "channel", channel, value: on ? "opt_in" : "opt_out" }] };
}

/** The write of a workflow switch. */
export function workflowWrite(workflow: string, on: boolean): PreferencesPatch {
  return { preferences: [{ level: "workflow", workflow, value: on ? "opt_in" : "opt_out" }] };
}

/** The write that unmutes a single object (§13.4.1). */
export function unmuteWrite(scopeKey: string): PreferencesPatch {
  return { preferences: [{ level: "scope_key", scope_key: scopeKey, value: "unset" }] };
}

/** Applies a patch to the view at once, before the server answers. */
export function applyPatch(view: PreferencesView, patch: PreferencesPatch): PreferencesView {
  let next: PreferencesView = view;
  for (const write of patch.preferences ?? []) {
    switch (write.level) {
      case "category_channel":
        next = {
          ...next,
          cells: next.cells.map((cell) =>
            cell.category === write.category && cell.channel === write.channel
              ? {
                  ...cell,
                  value: write.value,
                  effective:
                    write.value === "opt_out"
                      ? false
                      : write.value === "opt_in"
                        ? true
                        : cell.effective,
                }
              : cell,
          ),
        };
        break;
      case "channel":
        next = {
          ...next,
          channels: upsert(next.channels, "channel", write.channel ?? "", write.value),
        };
        break;
      case "workflow":
        next = {
          ...next,
          workflows: upsert(next.workflows, "workflow", write.workflow ?? "", write.value),
        };
        break;
      case "scope_key":
        next = {
          ...next,
          scope_keys: upsert(next.scope_keys, "scope_key", write.scope_key ?? "", write.value),
        };
        break;
    }
  }
  if (patch.profile !== undefined)
    next = { ...next, profile: { ...next.profile, ...patch.profile } };
  return next;
}

function upsert<
  K extends string,
  T extends { readonly value: PreferenceValue } & Record<K, string>,
>(list: readonly T[], key: K, name: string, value: PreferenceValue): T[] {
  const found = list.some((entry) => entry[key] === name);
  if (found) return list.map((entry) => (entry[key] === name ? { ...entry, value } : entry));
  return [...list, { [key]: name, value } as unknown as T];
}

/** Whether a time range is valid: well formed and start and end differ. */
export function validRange(range: TimeRange): boolean {
  const pattern = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
  return pattern.test(range.start) && pattern.test(range.end) && range.start !== range.end;
}
