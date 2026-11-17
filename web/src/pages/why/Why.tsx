import { useId, useState, type SyntheticEvent } from "react";
import { useGet } from "../../api/hooks";
import type {
  Consent,
  DecisionStep,
  DeliveryDecision,
  Device,
  NotificationDecision,
  Page,
  Subscriber,
  SubscriberPreferences,
} from "../../api/types";
import { Link, useRouter } from "../../app/router";
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
import { maskField } from "../../components/mask";
import { MaskedValue } from "../../components/MaskedValue";
import { RuleSentence } from "../../components/rule";
import { ChannelLabel, StatusBadge } from "../../components/status";
import { useI18n } from "../../i18n/i18n";
import { parseLookup, type Lookup } from "./lookup";

function detailEntries(step: DecisionStep): [string, string][] {
  const detail = (step.detail ?? {}) as Record<string, unknown>;
  return Object.entries(detail).map(([key, value]) => [
    key,
    typeof value === "string" ? value : JSON.stringify(value),
  ]);
}

function Step({ step }: { step: DecisionStep }) {
  const { t } = useI18n();
  const entries = detailEntries(step);
  const level = entries.find(([key]) => key === "level");
  return (
    <li className="stack step" data-step-rule={step.rule_id}>
      <RuleSentence ruleId={step.rule_id} description={step.description} />
      <span className="row muted">
        <Time value={step.occurred_at} />
        <span>{step.type}</span>
        {step.outcome && <span>{step.outcome}</span>}
        {step.reason && <code>{step.reason}</code>}
      </span>
      {level && (
        <span>
          {t("why.closingLevel")}: <code>{level[1]}</code>
        </span>
      )}
      {entries.length > 0 && (
        <KeyValues
          items={entries.map(([key, value]) => [
            key,
            <code key={key}>{value}</code>,
          ])}
        />
      )}
    </li>
  );
}

function DeliveryDecisionView({ decision }: { decision: DeliveryDecision }) {
  const { t } = useI18n();
  const main = decision.decisions.find(
    (step) => step.rule_id === decision.rule_id,
  );
  return (
    <li className="panel stack" data-delivery={decision.delivery_id}>
      <div className="row">
        <strong>
          <ChannelLabel channel={decision.channel} />
        </strong>
        <StatusBadge status={decision.status} channel={decision.channel} />
        <span className="muted">
          {t("why.gates")}: {t(`why.gate.${decision.gates}`)}
        </span>
      </div>
      {decision.rule_id && (
        <p className="answer">
          <RuleSentence
            ruleId={decision.rule_id}
            description={main?.description ?? null}
          />
        </p>
      )}
      {decision.deferred_until && (
        <p>
          {t("history.deferredUntil")}: <Time value={decision.deferred_until} />
        </p>
      )}
      {decision.decisions.length > 0 && (
        <details>
          <summary>
            {t("why.chain", { count: decision.decisions.length })}
          </summary>
          <ol className="stack">
            {decision.decisions.map((step, index) => (
              <Step key={`${step.rule_id}-${index}`} step={step} />
            ))}
          </ol>
        </details>
      )}
    </li>
  );
}

function Decisions({ subscriber }: { subscriber: Subscriber }) {
  const { t } = useI18n();
  const decisions = useGet<Page<NotificationDecision>>(
    `/v1/subscribers/${encodeURIComponent(subscriber.external_id)}/decisions`,
    { limit: 100 },
  );
  return (
    <Section title={t("why.decisions")}>
      <Loadable state={decisions.state} onRetry={decisions.reload}>
        {(page) =>
          page.data.length === 0 ? (
            <p className="muted">{t("why.noDecisions")}</p>
          ) : (
            <ol className="stack plain">
              {page.data.map((item) => (
                <li
                  key={item.notification_id}
                  className="stack"
                  data-notification={item.notification_id}
                >
                  <div className="row">
                    <Time value={item.created_at} />
                    <Mono>
                      {item.workflow.key} v{item.workflow.version}
                    </Mono>
                    <span className="muted">{item.state}</span>
                    {item.close_rule_id && <Mono>{item.close_rule_id}</Mono>}
                    <Link
                      to={`/activity/notifications/${item.notification_id}`}
                    >
                      {t("why.openNotification")}
                    </Link>
                  </div>
                  <ul className="stack plain">
                    {item.deliveries.map((delivery) => (
                      <DeliveryDecisionView
                        key={delivery.delivery_id}
                        decision={delivery}
                      />
                    ))}
                  </ul>
                </li>
              ))}
            </ol>
          )
        }
      </Loadable>
    </Section>
  );
}

export function Consents({ subscriber }: { subscriber: Subscriber }) {
  const { t } = useI18n();
  const consents = useGet<Page<Consent>>(
    `/v1/subscribers/${encodeURIComponent(subscriber.external_id)}/consents`,
    { limit: 100 },
  );
  const columns: Column<Consent>[] = [
    {
      key: "channel",
      header: t("why.channel"),
      render: (row) => <ChannelLabel channel={row.channel} />,
    },
    {
      key: "status",
      header: t("status.label"),
      render: (row) => t(`consent.${row.status}`),
    },
    {
      key: "kind",
      header: t("why.consentKind"),
      render: (row) => <Dash value={row.consent_kind} />,
    },
    { key: "source", header: t("why.source"), render: (row) => row.source },
    {
      key: "date",
      header: t("why.date"),
      render: (row) => <Time value={row.occurred_at} />,
    },
  ];
  return (
    <Section title={t("why.consents")}>
      <Loadable state={consents.state} onRetry={consents.reload}>
        {(page) => (
          <DataTable
            caption={t("why.consents")}
            columns={columns}
            rows={page.data}
            rowKey={(row) => row.id}
          />
        )}
      </Loadable>
    </Section>
  );
}

export function Preferences({ subscriber }: { subscriber: Subscriber }) {
  const { t } = useI18n();
  const preferences = useGet<SubscriberPreferences>(
    `/v1/subscribers/${encodeURIComponent(subscriber.external_id)}/preferences`,
  );
  type Cell = SubscriberPreferences["cells"][number];
  const cells: Column<Cell>[] = [
    {
      key: "category",
      header: t("why.category"),
      render: (row) => row.category,
    },
    {
      key: "channel",
      header: t("why.channel"),
      render: (row) => <ChannelLabel channel={row.channel} />,
    },
    {
      key: "value",
      header: t("why.value"),
      render: (row) => t(`preference.${row.value}`),
    },
    {
      key: "effective",
      header: t("why.effective"),
      render: (row) => (row.effective ? t("common.yes") : t("common.no")),
    },
    {
      key: "source",
      header: t("why.source"),
      render: (row) => t(`preference.source.${row.source}`),
    },
  ];
  return (
    <Section title={t("why.preferences")}>
      <Loadable state={preferences.state} onRetry={preferences.reload}>
        {(data) => (
          <div className="stack">
            <h3>{t("why.level.categoryChannel")}</h3>
            <DataTable
              caption={t("why.level.categoryChannel")}
              columns={cells}
              rows={data.cells}
              rowKey={(row) => `${row.category}/${row.channel}`}
            />
            <KeyValues
              items={[
                [
                  t("why.level.channel"),
                  data.channels.length === 0
                    ? "—"
                    : data.channels
                        .map(
                          (item) =>
                            `${item.channel}: ${t(`preference.${item.value}`)}`,
                        )
                        .join(", "),
                ],
                [
                  t("why.level.workflow"),
                  data.workflows.length === 0
                    ? "—"
                    : data.workflows
                        .map(
                          (item) =>
                            `${item.workflow}: ${t(`preference.${item.value}`)}`,
                        )
                        .join(", "),
                ],
                [
                  t("why.level.object"),
                  data.scope_keys.length === 0
                    ? "—"
                    : data.scope_keys
                        .map(
                          (item) =>
                            `${item.scope_key}: ${t(`preference.${item.value}`)}`,
                        )
                        .join(", "),
                ],
                [
                  t("why.level.schedule"),
                  data.profile.schedule.length === 0
                    ? "—"
                    : data.profile.schedule
                        .map(
                          (range) => `${range.day} ${range.start}–${range.end}`,
                        )
                        .join(", "),
                ],
                [
                  t("why.quietHours"),
                  data.profile.quiet_hours.length === 0
                    ? "—"
                    : data.profile.quiet_hours
                        .map(
                          (range) => `${range.day} ${range.start}–${range.end}`,
                        )
                        .join(", "),
                ],
                [
                  t("why.dndUntil"),
                  <Time key="d" value={data.profile.dnd_until} />,
                ],
              ]}
            />
          </div>
        )}
      </Loadable>
    </Section>
  );
}

export function Devices({ subscriber }: { subscriber: Subscriber }) {
  const { t } = useI18n();
  const devices = useGet<Page<Device>>(
    `/v1/subscribers/${encodeURIComponent(subscriber.external_id)}/devices`,
    { limit: 100 },
  );
  const columns: Column<Device>[] = [
    {
      key: "platform",
      header: t("why.platform"),
      render: (row) => row.platform,
    },
    {
      key: "app",
      header: t("why.app"),
      render: (row) => <Mono>{row.app}</Mono>,
    },
    {
      key: "permission",
      header: t("why.permission"),
      render: (row) => t(`device.permission.${row.permission}`),
    },
    { key: "state", header: t("status.label"), render: (row) => row.state },
    {
      key: "disabled",
      header: t("why.disabledReason"),
      render: (row) => <Dash value={row.disabled_reason} />,
    },
    {
      key: "seen",
      header: t("why.lastSeen"),
      render: (row) => <Time value={row.last_seen_at} />,
    },
  ];
  return (
    <Section title={t("why.devices")}>
      <Loadable state={devices.state} onRetry={devices.reload}>
        {(page) => (
          <DataTable
            caption={t("why.devices")}
            columns={columns}
            rows={page.data}
            rowKey={(row) => row.id}
          />
        )}
      </Loadable>
    </Section>
  );
}

// X-5
export function Profile({ subscriber }: { subscriber: Subscriber }) {
  const { t } = useI18n();
  const reach = Object.entries(subscriber.channels);
  return (
    <Section title={t("why.profile")}>
      <KeyValues
        items={[
          [
            t("why.recipientId"),
            <Mono key="id">{subscriber.external_id}</Mono>,
          ],
          [
            t("pii.field.email"),
            <MaskedValue
              key="email"
              subscriberId={subscriber.id}
              field="email"
              masked={maskField("email", subscriber.email)}
            />,
          ],
          [
            t("pii.field.phone"),
            <MaskedValue
              key="phone"
              subscriberId={subscriber.id}
              field="phone"
              masked={maskField("phone", subscriber.phone)}
            />,
          ],
          [
            t("pii.field.name"),
            <MaskedValue
              key="name"
              subscriberId={subscriber.id}
              field="name"
              masked={maskField("name", subscriber.name)}
            />,
          ],
          [t("why.locale"), <Dash key="l" value={subscriber.locale} />],
          [t("why.timezone"), <Dash key="z" value={subscriber.timezone} />],
          [t("activity.state"), subscriber.state],
        ]}
      />
      {reach.length > 0 && (
        <>
          <h3>{t("why.reachability")}</h3>
          <ul className="plain stack">
            {reach.map(([channel, value]) => (
              <li key={channel} className="row">
                <strong>{channel}</strong>
                <span>
                  {value.reachable ? t("why.reachable") : t("why.unreachable")}
                </span>
                {value.reason && <code>{value.reason}</code>}
              </li>
            ))}
          </ul>
        </>
      )}
    </Section>
  );
}

// X-12
export function WhyResult({ subscriber }: { subscriber: Subscriber }) {
  return (
    <div className="stack" data-subscriber={subscriber.id}>
      <Decisions subscriber={subscriber} />
      <Consents subscriber={subscriber} />
      <Preferences subscriber={subscriber} />
      <Devices subscriber={subscriber} />
      <Profile subscriber={subscriber} />
    </div>
  );
}

function WhyLookup({ lookup }: { lookup: Lookup }) {
  const { t } = useI18n();
  const [chosen, setChosen] = useState<Subscriber | null>(null);
  const byId = useGet<Subscriber>(
    lookup.kind === "id"
      ? `/v1/subscribers/${encodeURIComponent(lookup.value)}`
      : null,
  );
  const byContact = useGet<Page<Subscriber>>(
    lookup.kind === "id" ? null : "/v1/subscribers",
    lookup.kind === "id" ? {} : { [lookup.kind]: lookup.value, limit: 10 },
  );

  if (chosen) return <WhyResult subscriber={chosen} />;
  if (lookup.kind === "id")
    return (
      <Loadable state={byId.state} onRetry={byId.reload}>
        {(subscriber) => <WhyResult subscriber={subscriber} />}
      </Loadable>
    );
  return (
    <Loadable state={byContact.state} onRetry={byContact.reload}>
      {(page) => {
        const [first, ...rest] = page.data;
        if (first === undefined)
          return <p role="status">{t("why.noRecipient")}</p>;
        if (rest.length === 0) return <WhyResult subscriber={first} />;
        return (
          <div className="stack">
            <p role="status">{t("why.manyRecipients")}</p>
            <ul className="plain stack">
              {page.data.map((subscriber) => (
                <li key={subscriber.id}>
                  <button
                    type="button"
                    onClick={() => {
                      setChosen(subscriber);
                    }}
                  >
                    {subscriber.external_id}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        );
      }}
    </Loadable>
  );
}

// X-12
// X-13
export function Why() {
  const { t } = useI18n();
  const inputId = useId();
  const hintId = useId();
  const { location } = useRouter();
  const initial = location.search.get("recipient") ?? "";
  const [input, setInput] = useState(initial);
  const [lookup, setLookup] = useState<Lookup | null>(() =>
    parseLookup(initial),
  );
  const [round, setRound] = useState(0);

  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    setLookup(parseLookup(input));
    setRound((value) => value + 1);
  };

  return (
    <section className="stack">
      <h1>{t("nav.why")}</h1>
      <form className="row filters" role="search" onSubmit={submit}>
        <div className="field grow">
          <label htmlFor={inputId}>{t("why.input")}</label>
          <input
            id={inputId}
            value={input}
            aria-describedby={hintId}
            autoComplete="off"
            spellCheck={false}
            onChange={(event) => {
              setInput(event.target.value);
            }}
          />
          <span id={hintId} className="muted small">
            {t("why.inputHint")}
          </span>
        </div>
        <button type="submit" className="primary">
          {t("why.search")}
        </button>
      </form>
      <p className="muted small">{t("why.privacy")}</p>
      {lookup && <WhyLookup key={`${round}`} lookup={lookup} />}
    </section>
  );
}
