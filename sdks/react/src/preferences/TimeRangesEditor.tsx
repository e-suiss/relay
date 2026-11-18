import { useId, useState, type ReactNode } from "react";
import { useRelay } from "../context.js";
import type { MessageKey } from "../i18n/index.js";
import { validRange, type TimeRange } from "./model.js";

const days: readonly TimeRange["day"][] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

/** Props of {@link TimeRangesEditor}. */
export interface TimeRangesEditorProps {
  readonly title: string;
  readonly hint: string;
  readonly ranges: readonly TimeRange[];
  readonly onSave: (ranges: TimeRange[]) => void;
  readonly saving: boolean;
  readonly children?: ReactNode;
}

/** Edits weekly time ranges: the weekly schedule or quiet hours (§13.4.1, §13.9.1). */
export function TimeRangesEditor({ title, hint, ranges, onSave, saving, children }: TimeRangesEditorProps): ReactNode {
  const { t } = useRelay();
  const [draft, setDraft] = useState<TimeRange[]>(() => [...ranges]);
  const [invalid, setInvalid] = useState(false);
  const headingId = useId();
  const hintId = useId();
  const set = (index: number, change: Partial<TimeRange>) =>
    setDraft((current) => current.map((range, at) => (at === index ? { ...range, ...change } : range)));
  const save = () => {
    if (!draft.every(validRange)) {
      setInvalid(true);
      return;
    }
    setInvalid(false);
    onSave(draft);
  };
  return (
    <section className="relay-card" aria-labelledby={headingId}>
      <h3 className="relay-subheading" id={headingId}>
        {title}
      </h3>
      <p className="relay-muted" id={hintId}>
        {hint}
      </p>
      <ul className="relay-list">
        {draft.map((range, index) => {
          const dayLabel = t(`day.${range.day}` as MessageKey);
          return (
            <li key={index} className="relay-row" style={{ marginBottom: "0.5em" }}>
              <label className="relay-field">
                <span>{t("prefs.day")}</span>
                <select
                  className="relay-select"
                  value={range.day}
                  onChange={(event) => set(index, { day: event.target.value as TimeRange["day"] })}
                >
                  {days.map((day) => (
                    <option key={day} value={day}>
                      {t(`day.${day}` as MessageKey)}
                    </option>
                  ))}
                </select>
              </label>
              <label className="relay-field">
                <span>{t("prefs.start")}</span>
                <input
                  className="relay-input"
                  type="time"
                  value={range.start}
                  onChange={(event) => set(index, { start: event.target.value })}
                />
              </label>
              <label className="relay-field">
                <span>{t("prefs.end")}</span>
                <input
                  className="relay-input"
                  type="time"
                  value={range.end}
                  onChange={(event) => set(index, { end: event.target.value })}
                />
              </label>
              <button
                type="button"
                className="relay-button relay-button-small"
                onClick={() => setDraft((current) => current.filter((_, at) => at !== index))}
              >
                {t("prefs.removeRange", { day: dayLabel, start: range.start, end: range.end })}
              </button>
            </li>
          );
        })}
      </ul>
      {children}
      {invalid ? (
        <p className="relay-error" role="alert">
          {t("prefs.rangeInvalid")}
        </p>
      ) : null}
      <div className="relay-row">
        <button
          type="button"
          className="relay-button"
          onClick={() => setDraft((current) => [...current, { day: "mon", start: "09:00", end: "18:00" }])}
        >
          {t("prefs.addRange")}
        </button>
        <button type="button" className="relay-button" onClick={save} aria-disabled={saving}>
          {t("common.save")}
        </button>
      </div>
    </section>
  );
}
