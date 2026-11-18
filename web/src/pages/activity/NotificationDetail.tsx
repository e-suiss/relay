import { useState } from "react";
import { useGet } from "../../api/hooks";
import type {
  Attempt,
  Delivery,
  DeliveryHistory as History,
  LedgerEvent,
  Notification,
  Page,
} from "../../api/types";
import { Link } from "../../app/router";
import {
  DataTable,
  Dash,
  KeyValues,
  Loadable,
  Mono,
  Section,
  Time,
  type Column,
} from "../../components/data";
import {
  ChannelLabel,
  ChannelSemantics,
  OpenTrackingNotice,
  SenderTypeBadge,
  StatusBadge,
} from "../../components/status";
import { useI18n } from "../../i18n/i18n";

// DS-12
// X-6
export function DeliveryHistory({ delivery }: { delivery: Delivery }) {
  const { t } = useI18n();
  const history = useGet<History>(
    `/v1/deliveries/${encodeURIComponent(delivery.id)}/history`,
  );

  const attempts: Column<Attempt>[] = [
    { key: "no", header: "#", render: (row) => row.attempt_no },
    { key: "state", header: t("status.label"), render: (row) => row.state },
    {
      key: "provider",
      header: t("history.provider"),
      render: (row) => <Dash value={row.provider} />,
    },
    {
      key: "class",
      header: t("history.failureClass"),
      render: (row) => <Dash value={row.failure_class} />,
    },
    {
      key: "raw",
      header: t("history.rawResponse"),
      render: (row) => (row.raw_code ? <Mono>{row.raw_code}</Mono> : "—"),
    },
    {
      key: "started",
      header: t("history.started"),
      render: (row) => <Time value={row.started_at} />,
    },
    {
      key: "finished",
      header: t("history.finished"),
      render: (row) => <Time value={row.finished_at} />,
    },
  ];

  const events: Column<LedgerEvent>[] = [
    {
      key: "occurred",
      header: t("history.occurred"),
      render: (row) => <Time value={row.occurred_at} />,
    },
    { key: "type", header: t("history.event"), render: (row) => row.type },
    { key: "actor", header: t("history.actor"), render: (row) => row.actor },
    {
      key: "outcome",
      header: t("history.outcome"),
      render: (row) => <Dash value={row.outcome} />,
    },
    {
      key: "rule",
      header: "rule_id",
      render: (row) => (row.rule_id ? <Mono>{row.rule_id}</Mono> : "—"),
    },
    {
      key: "raw",
      header: t("history.rawResponse"),
      render: (row) => (row.raw_code ? <Mono>{row.raw_code}</Mono> : "—"),
    },
    {
      key: "received",
      header: t("history.received"),
      render: (row) => <Time value={row.received_at} />,
    },
  ];

  return (
    <div className="stack">
      <ChannelSemantics channel={delivery.channel} />
      {delivery.channel === "email" && <OpenTrackingNotice />}
      <Loadable state={history.state} onRetry={history.reload}>
        {(data) => (
          <>
            <h3>{t("history.attempts")}</h3>
            <DataTable
              caption={t("history.attempts")}
              columns={attempts}
              rows={data.attempts}
              rowKey={(row) => row.id}
            />
            <h3>{t("history.ledger")}</h3>
            <DataTable
              caption={t("history.ledger")}
              columns={events}
              rows={data.events}
              rowKey={(row) => row.id}
            />
          </>
        )}
      </Loadable>
    </div>
  );
}

function DeliveryRow({ delivery }: { delivery: Delivery }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const clicked = delivery.engagement?.clicked_by;
  return (
    <li className="panel stack" data-delivery={delivery.id}>
      <div className="row">
        <strong>
          <ChannelLabel channel={delivery.channel} />
        </strong>
        <StatusBadge status={delivery.status} channel={delivery.channel} />
        {delivery.rule_id && <Mono>{delivery.rule_id}</Mono>}
        {delivery.reason && <span className="muted">{delivery.reason}</span>}
        <button
          type="button"
          aria-expanded={open}
          onClick={() => {
            setOpen(!open);
          }}
        >
          {open ? t("history.hide") : t("history.show")}
        </button>
      </div>
      <KeyValues
        items={[
          [
            t("history.accepted"),
            <Time key="a" value={delivery.accepted_at} />,
          ],
          [
            t("history.deliveredAt"),
            <Time key="d" value={delivery.delivered_at} />,
          ],
          [
            t("history.deferredUntil"),
            <Time key="u" value={delivery.deferred_until} />,
          ],
          [
            t("history.fallbackOf"),
            delivery.fallback_of ? <Mono>{delivery.fallback_of}</Mono> : "—",
          ],
          [
            t("engagement.clicks"),
            clicked
              ? t(
                  clicked === "human"
                    ? "history.clickHuman"
                    : "history.clickBot",
                )
              : "—",
          ],
          [
            t("history.failure"),
            delivery.failure
              ? `${delivery.failure.kind} · ${delivery.failure.class}`
              : "—",
          ],
        ]}
      />
      {open && <DeliveryHistory delivery={delivery} />}
    </li>
  );
}

// X-1
// X-6
export function NotificationDetail({ id }: { id: string }) {
  const { t } = useI18n();
  const path = `/v1/notifications/${encodeURIComponent(id)}`;
  const notification = useGet<Notification>(path);
  const deliveries = useGet<Page<Delivery>>(`${path}/deliveries`, {
    limit: 100,
  });

  return (
    <section className="stack">
      <p>
        <Link to="/activity">{t("activity.back")}</Link>
      </p>
      <h1>
        {t("activity.notification")} <Mono>{id}</Mono>
      </h1>
      <Loadable state={notification.state} onRetry={notification.reload}>
        {(row) => (
          <KeyValues
            items={[
              [t("activity.created"), <Time key="c" value={row.created_at} />],
              [
                t("activity.workflow"),
                <Mono key="w">
                  {row.workflow.key} v{row.workflow.version}
                </Mono>,
              ],
              [
                t("activity.recipient"),
                <Mono key="r">{row.external_id ?? row.recipient_id}</Mono>,
              ],
              [
                t("sender.label"),
                <SenderTypeBadge key="s" type={row.sender_type} />,
              ],
              [t("activity.class"), row.message_class],
              [t("activity.state"), row.state],
              [
                t("activity.closeRule"),
                row.close_rule_id ? <Mono>{row.close_rule_id}</Mono> : "—",
              ],
              [
                t("context.environment"),
                row.is_test ? t("env.test") : t("env.live"),
              ],
              [t("activity.event"), <Mono key="e">{row.event_id}</Mono>],
            ]}
          />
        )}
      </Loadable>
      <Section title={t("activity.deliveries")}>
        <Loadable state={deliveries.state} onRetry={deliveries.reload}>
          {(page) =>
            page.data.length === 0 ? (
              <p className="muted">{t("common.empty")}</p>
            ) : (
              <ul className="stack plain">
                {page.data.map((delivery) => (
                  <DeliveryRow key={delivery.id} delivery={delivery} />
                ))}
              </ul>
            )
          }
        </Loadable>
      </Section>
    </section>
  );
}
