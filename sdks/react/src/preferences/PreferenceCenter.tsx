import { RelayApiError } from "@esuiss/relay/browser";
import { Fragment, useCallback, useEffect, useId, useRef, useState, type ReactNode } from "react";
import { RelayRoot, useRelay } from "../context.js";
import type { MessageKey } from "../i18n/index.js";
import { glyphs, StatusGlyph } from "../icons.js";
import { noConsents, type ConsentSource, type ConsentView } from "../seams.js";
import { safeUrl } from "../url.js";
import {
  applyPatch,
  categoryRows,
  cellOf,
  cellState,
  cellWrite,
  channelColumns,
  channelWrite,
  digestChoiceWrite,
  needsDigestStep,
  normalisePreferences,
  rowOffWrite,
  unmuteWrite,
  workflowWrite,
  type CategoryRow,
  type CellState,
  type DigestChoice,
  type PreferencesPatch,
  type PreferencesView,
} from "./model.js";
import { TimeRangesEditor } from "./TimeRangesEditor.js";

/** Props of {@link PreferenceCenter}. */
export interface PreferenceCenterProps {
  /** A category to bring into view, as the inbox shortcut asks (X-16). */
  readonly focusCategory?: string | null;
  /** Reads the subscriber's consents for the read-only consent section (X-44). */
  readonly consents?: ConsentSource;
  /** Categories of the marketing class, until the cell carries its class. */
  readonly marketingCategories?: readonly string[];
  /** The label of a channel; the shipped texts otherwise. */
  readonly channelLabel?: (channel: string) => string;
  readonly headingLevel?: 2 | 3;
}

/** A switch with a visible On or Off text, so its state never depends on colour alone. */
export function Switch({
  label,
  on,
  onToggle,
  describedBy,
}: {
  readonly label: string;
  readonly on: boolean;
  readonly onToggle: () => void;
  readonly describedBy?: string;
}): ReactNode {
  const { t } = useRelay();
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      className="relay-switch"
      onClick={onToggle}
      {...(describedBy === undefined ? {} : { "aria-describedby": describedBy })}
    >
      <span className="relay-switch-track" aria-hidden="true" />
      <span aria-hidden="true">{on ? t("prefs.on") : t("prefs.off")}</span>
    </button>
  );
}

interface StepTarget {
  readonly category: string;
  readonly channel: string | null;
}

function DigestStep({
  title,
  onChoose,
  onCancel,
}: {
  readonly title: string;
  readonly onChoose: (choice: DigestChoice) => void;
  readonly onCancel: () => void;
}): ReactNode {
  const { t } = useRelay();
  const titleId = useId();
  const groupRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    groupRef.current?.focus();
  }, []);
  return (
    <div
      className="relay-dialog"
      role="group"
      aria-labelledby={titleId}
      tabIndex={-1}
      ref={groupRef}
      data-testid="relay-digest-step"
    >
      <p className="relay-label" id={titleId}>
        {title}
      </p>
      <div className="relay-choice-group">
        {(["instant", "digest", "never"] as const).map((choice) => (
          <button
            key={choice}
            type="button"
            className="relay-choice"
            onClick={() => onChoose(choice)}
            data-choice={choice}
          >
            {choice === "instant"
              ? t("prefs.stepInstant")
              : choice === "digest"
                ? t("prefs.stepDigest")
                : t("prefs.stepNever")}
          </button>
        ))}
      </div>
      <div className="relay-row" style={{ marginTop: "0.5em" }}>
        <button type="button" className="relay-button relay-button-small" onClick={onCancel}>
          {t("common.cancel")}
        </button>
      </div>
    </div>
  );
}

function errorKey(error: unknown): MessageKey {
  if (error instanceof RelayApiError) {
    if (error.code === "preference_last_channel") return "prefs.lastChannel";
    if (error.code === "preference_digest_not_allowed") return "prefs.digestNotAllowed";
  }
  return "prefs.saveFailed";
}

function ConsentSection({
  consents,
  channelName,
}: {
  readonly consents: readonly ConsentView[] | null;
  readonly channelName: (channel: string) => string;
}): ReactNode {
  const { t, links } = useRelay();
  const headingId = useId();
  const href = safeUrl(links.accessConsentUrl);
  return (
    <section className="relay-card" aria-labelledby={headingId} data-testid="relay-consents">
      <h3 className="relay-subheading" id={headingId}>
        {t("prefs.consents")}
      </h3>
      <p className="relay-muted">{t("prefs.consentsHint")}</p>
      {consents === null || consents.length === 0 ? (
        <p>{t("prefs.consentsUnavailable")}</p>
      ) : (
        <ul className="relay-list">
          {consents.map((consent, index) => (
            <li key={`${consent.channel}-${consent.brand ?? ""}-${index}`}>
              {t("prefs.consentStatus", {
                channel: channelName(consent.channel),
                status: t(`consent.${consent.status}` as MessageKey),
              })}
            </li>
          ))}
        </ul>
      )}
      {href === null ? null : (
        <a className="relay-link" href={href}>
          {t("prefs.manageConsents")}
        </a>
      )}
    </section>
  );
}

/** The preference center without its themed root; {@link PreferenceCenter} wraps it. */
export function PreferenceCenterPanel({
  focusCategory = null,
  consents: consentSource = noConsents,
  marketingCategories,
  channelLabel,
  headingLevel = 2,
}: PreferenceCenterProps): ReactNode {
  const { runtime, t, links } = useRelay();
  const client = runtime.subscriber;
  const [view, setView] = useState<PreferencesView | null>(null);
  const [loadError, setLoadError] = useState(false);
  const [message, setMessage] = useState<{ readonly error: boolean; readonly text: string } | null>(
    null,
  );
  const [consents, setConsents] = useState<readonly ConsentView[] | null>(null);
  const [step, setStep] = useState<StepTarget | null>(null);
  const [saving, setSaving] = useState(false);
  const headingId = useId();
  const rowRefs = useRef(new Map<string, HTMLTableCellElement>());
  const channelName = useCallback(
    (channel: string) => channelLabel?.(channel) ?? t(`channel.${channel}` as MessageKey),
    [channelLabel, t],
  );

  const load = useCallback(() => {
    if (client === null) return;
    setLoadError(false);
    client
      .call("getMyPreferences")
      .then((result) => setView(normalisePreferences(result)))
      .catch(() => setLoadError(true));
  }, [client]);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    let active = true;
    consentSource()
      .then((result) => {
        if (active) setConsents(result);
      })
      .catch(() => {
        if (active) setConsents(null);
      });
    return () => {
      active = false;
    };
  }, [consentSource]);

  const loaded = view !== null;
  useEffect(() => {
    if (!loaded || focusCategory === null) return;
    const row = rowRefs.current.get(focusCategory);
    row?.scrollIntoView?.({ block: "center" });
    row?.focus();
  }, [loaded, focusCategory]);

  const save = (patch: PreferencesPatch) => {
    if (client === null || view === null) return;
    const previous = view;
    setView(applyPatch(view, patch));
    setStep(null);
    setSaving(true);
    setMessage(null);
    client
      .call("updateMyPreferences", { body: patch } as never)
      .then((result) => {
        setView(normalisePreferences(result));
        setMessage({ error: false, text: t("common.saved") });
      })
      .catch((error: unknown) => {
        setView(previous);
        setMessage({ error: true, text: t(errorKey(error)) });
      })
      .finally(() => setSaving(false));
  };

  const Heading = headingLevel === 2 ? "h2" : "h3";
  if (client === null) return null;
  if (view === null) {
    return (
      <section className="relay-preferences" aria-labelledby={headingId}>
        <Heading className="relay-heading" id={headingId}>
          {t("prefs.title")}
        </Heading>
        {loadError ? (
          <div className="relay-notice" role="alert">
            <span className="relay-error">{t("common.error")}</span>
            <button type="button" className="relay-button relay-button-small" onClick={load}>
              {t("common.retry")}
            </button>
          </div>
        ) : (
          <p className="relay-muted" aria-busy="true">
            {t("common.loading")}
          </p>
        )}
      </section>
    );
  }

  const marketing = new Set(marketingCategories ?? []);
  const columns = channelColumns(view);
  const rows = categoryRows(view, marketing);
  const consentHref = safeUrl(links.accessConsentUrl);
  const channelOn = (channel: string) =>
    view.channels.find((entry) => entry.channel === channel)?.value !== "opt_out";

  const toggleCell = (row: CategoryRow, channel: string, state: CellState) => {
    if (state.kind !== "switch") return;
    if (needsDigestStep(state)) {
      setStep({ category: row.category, channel });
      return;
    }
    save(cellWrite({ category: row.category, channel }, !state.on));
  };

  const rowOff = (row: CategoryRow) => {
    const patch = rowOffWrite(view, row, consents);
    if (patch === null) return;
    const digestible = view.cells.some(
      (cell) => cell.category === row.category && cell.digest_allowed,
    );
    if (digestible) setStep({ category: row.category, channel: null });
    else save(patch);
  };

  const choose = (target: StepTarget, choice: DigestChoice) => {
    if (target.channel !== null) {
      save(
        digestChoiceWrite(
          { category: target.category, channel: target.channel },
          choice,
          view.profile.digest,
        ),
      );
      return;
    }
    if (choice === "never") {
      const row = rows.find((entry) => entry.category === target.category);
      const patch = row === undefined ? null : rowOffWrite(view, row, consents);
      if (patch !== null) save(patch);
      else setStep(null);
      return;
    }
    save({ profile: { digest: { ...view.profile.digest, [target.category]: choice } } });
  };

  const renderCell = (row: CategoryRow, channel: string): ReactNode => {
    const cell = cellOf(view, row.category, channel);
    const state = cellState(cell, { marketing: row.marketing, consents });
    const label = t("prefs.cellLabel", { category: row.name, channel: channelName(channel) });
    switch (state.kind) {
      case "unavailable":
        return (
          <>
            <span aria-hidden="true">—</span>
            <span className="relay-sr-only">{t("prefs.unavailable")}</span>
          </>
        );
      case "locked":
        return (
          <span className="relay-status">
            <StatusGlyph glyph={state.on ? glyphs.locked : glyphs.off} />
            {state.on ? t("prefs.locked") : t("prefs.off")}
          </span>
        );
      case "admin_off":
        return (
          <span className="relay-status">
            <StatusGlyph glyph={glyphs.off} />
            {t("prefs.adminOff")}
          </span>
        );
      case "permission_pending":
        return (
          <span className="relay-status" data-testid="relay-permission-pending">
            <StatusGlyph glyph={glyphs.pending} />
            {t("prefs.permissionPending")}
            {consentHref === null ? null : (
              <>
                {" · "}
                <a className="relay-link" href={consentHref}>
                  {t("prefs.allow")}
                  <span className="relay-sr-only"> {label}</span>
                </a>
              </>
            )}
          </span>
        );
      case "switch": {
        const noteId = `${headingId}-${row.category}-${channel}-device`;
        const open = step !== null && step.category === row.category && step.channel === channel;
        return (
          <div className="relay-stack">
            <Switch
              label={label}
              on={state.on}
              onToggle={() => toggleCell(row, channel, state)}
              {...(state.deviceOff ? { describedBy: noteId } : {})}
            />
            {state.deviceOff ? (
              <span className="relay-status relay-muted" id={noteId}>
                <StatusGlyph glyph={glyphs.warning} />
                {t("prefs.deviceOff")}
              </span>
            ) : null}
            {open ? (
              <DigestStep
                title={t("prefs.stepTitle", { category: row.name })}
                onChoose={(choice) => choose({ category: row.category, channel }, choice)}
                onCancel={() => setStep(null)}
              />
            ) : null}
          </div>
        );
      }
    }
  };

  return (
    <section className="relay-preferences" aria-labelledby={headingId}>
      <Heading className="relay-heading" id={headingId}>
        {t("prefs.title")}
      </Heading>
      <div role="status" aria-live="polite">
        {message === null ? null : (
          <p className={message.error ? "relay-error" : "relay-success"}>{message.text}</p>
        )}
      </div>
      <div className="relay-matrix-scroll">
        <table className="relay-matrix" data-testid="relay-preference-matrix">
          <caption className="relay-sr-only">{t("prefs.title")}</caption>
          <thead>
            <tr>
              <th scope="col">{t("prefs.category")}</th>
              {columns.map((channel) => (
                <th scope="col" key={channel}>
                  <div className="relay-stack">
                    <span>{channelName(channel)}</span>
                    <Switch
                      label={t("prefs.channelAll", { channel: channelName(channel) })}
                      on={channelOn(channel)}
                      onToggle={() => save(channelWrite(channel, !channelOn(channel)))}
                    />
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const rowStep =
                step !== null && step.category === row.category && step.channel === null;
              const canTurnOff = rowOffWrite(view, row, consents) !== null;
              return (
                <Fragment key={row.category}>
                  <tr data-category={row.category}>
                    <th
                      scope="row"
                      tabIndex={-1}
                      ref={(element) => {
                        if (element === null) rowRefs.current.delete(row.category);
                        else rowRefs.current.set(row.category, element);
                      }}
                    >
                      <div className="relay-stack">
                        <span>{row.name}</span>
                        {row.locked ? (
                          <span
                            className="relay-status relay-muted"
                            data-testid="relay-lock-reason"
                          >
                            <StatusGlyph glyph={glyphs.locked} />
                            {row.beneficiary === "subscriber"
                              ? t("prefs.lockedSubscriber")
                              : row.beneficiary === "tenant"
                                ? t("prefs.lockedTenant")
                                : t("prefs.lockedGeneric")}
                          </span>
                        ) : null}
                        {canTurnOff ? (
                          <button
                            type="button"
                            className="relay-button relay-button-small"
                            onClick={() => rowOff(row)}
                          >
                            {t("prefs.rowOff", { category: row.name })}
                          </button>
                        ) : null}
                        {rowStep ? (
                          <DigestStep
                            title={t("prefs.stepTitle", { category: row.name })}
                            onChoose={(choice) =>
                              choose({ category: row.category, channel: null }, choice)
                            }
                            onCancel={() => setStep(null)}
                          />
                        ) : null}
                      </div>
                    </th>
                    {columns.map((channel) => (
                      <td key={channel}>{renderCell(row, channel)}</td>
                    ))}
                  </tr>
                </Fragment>
              );
            })}
          </tbody>
        </table>
      </div>

      <section className="relay-card" aria-labelledby={`${headingId}-workflows`}>
        <h3 className="relay-subheading" id={`${headingId}-workflows`}>
          {t("prefs.workflows")}
        </h3>
        {view.workflows.length === 0 ? (
          <p className="relay-muted">{t("prefs.workflowsEmpty")}</p>
        ) : (
          <ul className="relay-list">
            {view.workflows.map((entry) => {
              const on = entry.value !== "opt_out";
              return (
                <li key={entry.workflow} className="relay-row">
                  <span>{entry.workflow}</span>
                  <Switch
                    label={entry.workflow}
                    on={on}
                    onToggle={() => save(workflowWrite(entry.workflow, !on))}
                  />
                </li>
              );
            })}
          </ul>
        )}
      </section>

      <section className="relay-card" aria-labelledby={`${headingId}-scopes`}>
        <h3 className="relay-subheading" id={`${headingId}-scopes`}>
          {t("prefs.scopeKeys")}
        </h3>
        {view.scope_keys.filter((entry) => entry.value === "opt_out").length === 0 ? (
          <p className="relay-muted">{t("prefs.scopeEmpty")}</p>
        ) : (
          <ul className="relay-list">
            {view.scope_keys
              .filter((entry) => entry.value === "opt_out")
              .map((entry) => (
                <li key={entry.scope_key} className="relay-row">
                  <span className="relay-code">{entry.scope_key}</span>
                  <button
                    type="button"
                    className="relay-button relay-button-small"
                    onClick={() => save(unmuteWrite(entry.scope_key))}
                  >
                    {t("prefs.unmute", { name: entry.scope_key })}
                  </button>
                </li>
              ))}
          </ul>
        )}
      </section>

      <TimeRangesEditor
        title={t("prefs.schedule")}
        hint={t("prefs.scheduleHint")}
        ranges={view.profile.schedule}
        saving={saving}
        onSave={(ranges) => save({ profile: { schedule: ranges } })}
      />
      <TimeRangesEditor
        title={t("prefs.quietHours")}
        hint={t("prefs.quietHint")}
        ranges={view.profile.quiet_hours}
        saving={saving}
        onSave={(ranges) => save({ profile: { quiet_hours: ranges } })}
      >
        <label className="relay-check">
          <input
            type="checkbox"
            checked={view.profile.quiet_hours_email}
            onChange={(event) => save({ profile: { quiet_hours_email: event.target.checked } })}
          />
          {t("prefs.quietEmail")}
        </label>
      </TimeRangesEditor>

      <ConsentSection consents={consents} channelName={channelName} />
    </section>
  );
}

/**
 * The preference center (§8.7, X-18 … X-22, PC-6, PC-15 … PC-19): the category × channel matrix with the global channel switches, `—` for a cell that does not exist, locked categories as "On (locked)" with whom the lock serves, "turned off by your administrator", "turned off in device settings" and "Permission pending · Allow"; turning off a digestible cell offers Instant, Digest and Never with nothing preselected; notification types, single-object mutes, the weekly schedule, quiet hours with the e-mail choice and the marketing consents read-only with a link to Access (X-44). Switches turn on and off with one click each (X-20); it never asks for consent (X-21).
 */
export function PreferenceCenter(props: PreferenceCenterProps): ReactNode {
  return (
    <RelayRoot>
      <PreferenceCenterPanel {...props} />
    </RelayRoot>
  );
}
