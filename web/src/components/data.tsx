import type { ReactNode } from "react";
import { ApiError } from "../api/client";
import type { Load } from "../api/hooks";
import { useI18n } from "../i18n/i18n";

export function ErrorNotice({
  error,
  onRetry,
}: {
  error: unknown;
  onRetry?: () => void;
}) {
  const { t } = useI18n();
  let text: string;
  if (error instanceof ApiError && error.status === 403)
    text = t("error.forbidden");
  else if (error instanceof ApiError && error.status === 404)
    text = t("error.notFound");
  else if (error instanceof ApiError)
    text = t("error.generic", {
      detail: error.problem?.detail ?? error.problem?.title ?? error.message,
    });
  else text = t("error.generic", { detail: String(error) });
  return (
    <div className="panel stack" role="alert">
      <p>{text}</p>
      {error instanceof ApiError && error.code !== null && (
        <p className="muted">
          <code>{error.code}</code>
        </p>
      )}
      {onRetry && (
        <span>
          <button type="button" onClick={onRetry}>
            {t("error.retry")}
          </button>
        </span>
      )}
    </div>
  );
}

/** Renders the loading, error and ready states of one read. */
export function Loadable<T>({
  state,
  onRetry,
  children,
}: {
  state: Load<T>;
  onRetry?: () => void;
  children: (data: T) => ReactNode;
}) {
  const { t } = useI18n();
  if (state.kind === "loading")
    return (
      <p role="status" className="muted">
        {t("common.loading")}
      </p>
    );
  if (state.kind === "error")
    return (
      <ErrorNotice error={state.error} {...(onRetry ? { onRetry } : {})} />
    );
  return <>{children(state.data)}</>;
}

export interface Column<T> {
  key: string;
  header: string;
  render: (row: T) => ReactNode;
}

export function DataTable<T>({
  caption,
  columns,
  rows,
  rowKey,
}: {
  caption: string;
  columns: readonly Column<T>[];
  rows: readonly T[];
  rowKey: (row: T) => string;
}) {
  const { t } = useI18n();
  if (rows.length === 0)
    return (
      <p className="muted" role="status">
        {t("common.empty")}
      </p>
    );
  return (
    <div className="table-wrap">
      <table>
        <caption className="visually-hidden">{caption}</caption>
        <thead>
          <tr>
            {columns.map((column) => (
              <th key={column.key} scope="col">
                {column.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={rowKey(row)}>
              {columns.map((column) => (
                <td key={column.key}>{column.render(row)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Pager({
  hasPrevious,
  hasNext,
  onPrevious,
  onNext,
}: {
  hasPrevious: boolean;
  hasNext: boolean;
  onPrevious: () => void;
  onNext: () => void;
}) {
  const { t } = useI18n();
  if (!hasPrevious && !hasNext) return null;
  return (
    <nav className="row" aria-label={t("common.pages")}>
      <button type="button" onClick={onPrevious} disabled={!hasPrevious}>
        {t("common.previous")}
      </button>
      <button type="button" onClick={onNext} disabled={!hasNext}>
        {t("common.next")}
      </button>
    </nav>
  );
}

export function Time({ value }: { value: string | null | undefined }) {
  const { locale } = useI18n();
  if (value === null || value === undefined || value === "") return <>—</>;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return <>{value}</>;
  const text = new Intl.DateTimeFormat(locale === "tr" ? "tr-TR" : "en-GB", {
    dateStyle: "medium",
    timeStyle: "medium",
    timeZone: "UTC",
  }).format(date);
  return <time dateTime={value}>{text} UTC</time>;
}

export function Mono({ children }: { children: ReactNode }) {
  return <code className="mono">{children}</code>;
}

export function Dash({ value }: { value: ReactNode }) {
  return (
    <>{value === null || value === undefined || value === "" ? "—" : value}</>
  );
}

export function KeyValues({
  items,
}: {
  items: readonly (readonly [string, ReactNode])[];
}) {
  return (
    <dl className="key-values">
      {items.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}

export function Section({
  title,
  children,
  actions,
}: {
  title: string;
  children: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <section className="stack section">
      <div className="row section-head">
        <h2>{title}</h2>
        {actions}
      </div>
      {children}
    </section>
  );
}
