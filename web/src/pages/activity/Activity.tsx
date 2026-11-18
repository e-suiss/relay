import { useId, useState, type SyntheticEvent } from "react";
import { usePaged } from "../../api/hooks";
import type { DeliveryStatus, Notification } from "../../api/types";
import { Link } from "../../app/router";
import {
  DataTable,
  Loadable,
  Mono,
  Pager,
  Time,
  type Column,
} from "../../components/data";
import { SenderTypeBadge, StatusBadge } from "../../components/status";
import { useI18n } from "../../i18n/i18n";

export const deliveryStatuses: readonly DeliveryStatus[] = [
  "queued",
  "sent",
  "delivered",
  "unknown_pending",
  "unknown",
  "failed",
  "skipped",
  "expired",
  "cancelled",
];

interface Filters {
  subscriber: string;
  workflow: string;
  status: string;
  test: string;
}

const empty: Filters = { subscriber: "", workflow: "", status: "", test: "" };

export function DeliveryCounts({ row }: { row: Notification }) {
  const counts = row.delivery_counts;
  const present = deliveryStatuses.filter(
    (status) => (counts[status] ?? 0) > 0,
  );
  if (present.length === 0) return <>—</>;
  return (
    <span className="row">
      {present.map((status) => (
        <span key={status} className="row">
          <StatusBadge status={status} />
          <span>×{counts[status]}</span>
        </span>
      ))}
    </span>
  );
}

// X-1
// X-6
export function Activity() {
  const { t } = useI18n();
  const [draft, setDraft] = useState<Filters>(empty);
  const [filters, setFilters] = useState<Filters>(empty);
  const ids = {
    subscriber: useId(),
    workflow: useId(),
    status: useId(),
    test: useId(),
  };
  const paged = usePaged<Notification>("/v1/notifications", {
    subscriber: filters.subscriber,
    workflow: filters.workflow,
    status: filters.status,
    is_test: filters.test === "" ? undefined : filters.test === "true",
  });

  const apply = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    setFilters(draft);
  };

  const columns: Column<Notification>[] = [
    {
      key: "created",
      header: t("activity.created"),
      render: (row) => (
        <Link to={`/activity/notifications/${row.id}`}>
          <Time value={row.created_at} />
        </Link>
      ),
    },
    {
      key: "workflow",
      header: t("activity.workflow"),
      render: (row) => (
        <Mono>
          {row.workflow.key} v{row.workflow.version}
        </Mono>
      ),
    },
    {
      key: "recipient",
      header: t("activity.recipient"),
      render: (row) => <Mono>{row.external_id ?? row.recipient_id}</Mono>,
    },
    {
      key: "sender",
      header: t("sender.label"),
      render: (row) => <SenderTypeBadge type={row.sender_type} />,
    },
    {
      key: "deliveries",
      header: t("activity.deliveries"),
      render: (row) => <DeliveryCounts row={row} />,
    },
    {
      key: "rule",
      header: t("activity.closeRule"),
      render: (row) =>
        row.close_rule_id ? <Mono>{row.close_rule_id}</Mono> : "—",
    },
    {
      key: "plane",
      header: t("context.environment"),
      render: (row) => (row.is_test ? t("env.test") : t("env.live")),
    },
  ];

  return (
    <section className="stack">
      <h1>{t("nav.activity")}</h1>
      <form className="row filters" onSubmit={apply}>
        <div className="field">
          <label htmlFor={ids.subscriber}>{t("activity.recipient")}</label>
          <input
            id={ids.subscriber}
            value={draft.subscriber}
            onChange={(event) => {
              setDraft({ ...draft, subscriber: event.target.value.trim() });
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.workflow}>{t("activity.workflow")}</label>
          <input
            id={ids.workflow}
            value={draft.workflow}
            onChange={(event) => {
              setDraft({ ...draft, workflow: event.target.value.trim() });
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.status}>{t("status.label")}</label>
          <select
            id={ids.status}
            value={draft.status}
            onChange={(event) => {
              setDraft({ ...draft, status: event.target.value });
            }}
          >
            <option value="">{t("common.all")}</option>
            {deliveryStatuses.map((status) => (
              <option key={status} value={status}>
                {t(`status.${status}`)}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor={ids.test}>{t("activity.plane")}</label>
          <select
            id={ids.test}
            value={draft.test}
            onChange={(event) => {
              setDraft({ ...draft, test: event.target.value });
            }}
          >
            <option value="">{t("common.all")}</option>
            <option value="false">{t("activity.realSends")}</option>
            <option value="true">{t("activity.testSends")}</option>
          </select>
        </div>
        <button type="submit" className="primary">
          {t("common.filter")}
        </button>
      </form>
      <Loadable state={paged.state} onRetry={paged.reload}>
        {() => (
          <DataTable
            caption={t("nav.activity")}
            columns={columns}
            rows={paged.items}
            rowKey={(row) => row.id}
          />
        )}
      </Loadable>
      <Pager
        hasPrevious={paged.hasPrevious}
        hasNext={paged.hasNext}
        onPrevious={paged.previous}
        onNext={paged.next}
      />
    </section>
  );
}
