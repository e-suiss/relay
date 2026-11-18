import { useId, useState, type SyntheticEvent } from "react";
import { ApiError, etag, idempotencyKey } from "../../api/client";
import { useGet, useMutation } from "../../api/hooks";
import type { EscalationPolicyUsage, RouteUsage } from "../../api/pending";
import type { Channel, ServerSchemas } from "../../api/types";
import { Link, useRouter } from "../../app/router";
import {
  Loadable,
  Mono,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { ChannelLabel } from "../../components/status";
import { useI18n } from "../../i18n/i18n";
import { durationSeconds, humanDuration, isDuration } from "../../lib/duration";
import { problemText, useStepUp } from "../../session/stepUp";
import { channels, patterns } from "../workflows/model";
import { RouteTree } from "../workflows/RouteTree";
import { tierSpans } from "./timeline";

type Policy = ServerSchemas["EscalationPolicy"];
type PolicyVersion = ServerSchemas["EscalationPolicyVersion"];
type Tier = ServerSchemas["EscalationTier"];
type Responder = ServerSchemas["Responder"];
type Route = ServerSchemas["Route"];

const enc = encodeURIComponent;

function RouteUsageView({ routeKey }: { routeKey: string }) {
  const { t } = useI18n();
  const usage = useGet<RouteUsage>(`/v1/routes/${enc(routeKey)}/usage`);
  if (usage.state.kind === "loading")
    return <span className="small muted">{t("common.loading")}</span>;
  if (usage.state.kind === "error")
    return (
      <span className="small muted">
        {usage.state.error instanceof ApiError &&
        usage.state.error.status === 404
          ? t("esc.usageUnavailable")
          : problemText(usage.state.error)}
      </span>
    );
  const data = usage.state.data;
  if (data.workflows.length === 0 && data.categories.length === 0)
    return <span className="small muted">{t("esc.unused")}</span>;
  return (
    <ul className="plain small" data-route-usage={routeKey}>
      {data.workflows.map((item) => (
        <li key={`${item.key}-${item.state}`}>
          <Link to={`/workflows/${enc(item.key)}`}>{item.key}</Link>{" "}
          {t(`esc.usageState.${item.state}`)}
          {item.version !== null && ` v${item.version}`} ·{" "}
          {item.steps.join(", ")}
        </li>
      ))}
      {data.categories.map((category) => (
        <li key={category}>{t("esc.categoryDefault", { category })}</li>
      ))}
    </ul>
  );
}

// WF-13
// WF-21
function Routes() {
  const { t } = useI18n();
  const columns: Column<Route>[] = [
    {
      key: "key",
      header: t("esc.route"),
      render: (row) => (
        <span className="stack tight">
          <Mono>{row.key}</Mono>
          <span className="small">{row.name}</span>
        </span>
      ),
    },
    {
      key: "tree",
      header: t("esc.tree"),
      render: (row) => <RouteTree node={row.tree} />,
    },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
    {
      key: "usage",
      header: t("esc.usedBy"),
      render: (row) => <RouteUsageView routeKey={row.key} />,
    },
  ];
  return (
    <PagedTable
      title={t("esc.routes")}
      path="/v1/routes"
      columns={columns}
      rowKey={(row) => row.id}
    />
  );
}

function NewPolicy() {
  const { t } = useI18n();
  const { navigate } = useRouter();
  const id = useId();
  const [key, setKey] = useState("");
  const valid = patterns.slug.test(key);
  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (valid) navigate(`/escalation/policies/${enc(key)}`);
  };
  return (
    <form className="row filters" onSubmit={submit}>
      <div className="field">
        <label htmlFor={id}>{t("esc.policyKey")}</label>
        <input
          id={id}
          value={key}
          placeholder="on-call"
          aria-invalid={key !== "" && !valid}
          onChange={(event) => {
            setKey(event.target.value.trim());
          }}
        />
      </div>
      <button type="submit" disabled={!valid}>
        {t("esc.newPolicy")}
      </button>
    </form>
  );
}

// AG-17
export function Escalation() {
  const { t } = useI18n();
  const columns: Column<Policy>[] = [
    {
      key: "key",
      header: t("esc.policyKey"),
      render: (row) => (
        <Link to={`/escalation/policies/${enc(row.key)}`}>
          <Mono>{row.key}</Mono>
        </Link>
      ),
    },
    {
      key: "version",
      header: t("wf.version"),
      render: (row) => `v${row.version}`,
    },
    { key: "tiers", header: t("esc.tiers"), render: (row) => row.tiers.length },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
    {
      key: "description",
      header: t("wf.description"),
      render: (row) => row.description ?? "—",
    },
    {
      key: "updated",
      header: t("common.updated"),
      render: (row) => <Time value={row.updated_at} />,
    },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.escalation")}</h1>
      <p className="muted">{t("esc.intro")}</p>
      <PagedTable
        title={t("esc.policies")}
        path="/v1/escalation_policies"
        columns={columns}
        rowKey={(row) => row.id}
      />
      <NewPolicy />
      <Routes />
    </section>
  );
}

function Timeline({ tiers }: { tiers: readonly Tier[] }) {
  const { t, locale } = useI18n();
  const spans = tierSpans(tiers);
  if (spans === null || spans.length === 0)
    return <p className="small muted">{t("esc.timelineInvalid")}</p>;
  const end = spans.at(-1)?.opensAt ?? 1;
  return (
    <ol className="timeline plain" aria-label={t("esc.timeline")}>
      {spans.map((span) => (
        <li
          key={`${span.tier}-${span.repeat}`}
          className={`timeline-mark tier-${span.tier % 6}`}
          data-opens-at={span.opensAt}
          style={{ insetInlineStart: `${(span.opensAt / end) * 100}%` }}
        >
          <span className="small">
            {span.repeat === 0
              ? t("esc.tierN", { n: span.tier + 1 })
              : t("esc.repeatN", { n: span.tier + 1, repeat: span.repeat })}
            {" · "}
            {humanDuration(span.opensAt, locale)}
          </span>
        </li>
      ))}
    </ol>
  );
}

function ResponderRow({
  responder,
  index,
  onChange,
  onRemove,
}: {
  responder: Responder;
  index: number;
  onChange: (responder: Responder) => void;
  onRemove: () => void;
}) {
  const { t } = useI18n();
  const ids = { kind: useId(), id: useId() };
  return (
    <div className="row filters">
      <div className="field">
        <label htmlFor={ids.kind}>
          {t("esc.responderKind", { n: index + 1 })}
        </label>
        <select
          id={ids.kind}
          value={responder.kind}
          onChange={(event) => {
            onChange({
              ...responder,
              kind: event.target.value as Responder["kind"],
            });
          }}
        >
          <option value="subscriber">{t("esc.kind.subscriber")}</option>
          <option value="agent">{t("esc.kind.agent")}</option>
        </select>
      </div>
      <div className="field grow">
        <label htmlFor={ids.id}>{t("esc.responderId", { n: index + 1 })}</label>
        <input
          id={ids.id}
          value={responder.id}
          placeholder={responder.kind === "agent" ? "agt_…" : "user-42"}
          onChange={(event) => {
            onChange({ ...responder, id: event.target.value.trim() });
          }}
        />
      </div>
      <button type="button" onClick={onRemove}>
        {t("esc.removeResponder")}
      </button>
    </div>
  );
}

function TierCard({
  tier,
  index,
  count,
  onChange,
  onMove,
  onRemove,
}: {
  tier: Tier;
  index: number;
  count: number;
  onChange: (tier: Tier) => void;
  onMove: (to: number) => void;
  onRemove: () => void;
}) {
  const { t, locale } = useI18n();
  const ids = { after: useId(), repeat: useId(), skip: useId() };
  const seconds = durationSeconds(tier.after);
  const tooShort = seconds !== null && seconds < 60;
  const responders = tier.add_responders ?? [];
  const chosen = tier.channels ?? [];
  return (
    <li
      className="tier-card panel stack"
      data-tier={index}
      draggable
      onDragStart={(event) => {
        event.dataTransfer.setData("application/x-relay-tier", String(index));
      }}
      onDragOver={(event) => {
        event.preventDefault();
      }}
      onDrop={(event) => {
        event.preventDefault();
        const raw = event.dataTransfer.getData("application/x-relay-tier");
        const from = Number(raw);
        if (raw !== "" && Number.isInteger(from) && from !== index)
          onMove(from);
      }}
    >
      <div className="row section-head">
        <h3 className="small-heading">{t("esc.tierN", { n: index + 1 })}</h3>
        <span className="row">
          <button
            type="button"
            disabled={index === 0}
            aria-label={t("esc.moveUp", { n: index + 1 })}
            onClick={() => {
              onMove(-1);
            }}
          >
            ↑
          </button>
          <button
            type="button"
            disabled={index === count - 1}
            aria-label={t("esc.moveDown", { n: index + 1 })}
            onClick={() => {
              onMove(-2);
            }}
          >
            ↓
          </button>
          <button type="button" disabled={count === 1} onClick={onRemove}>
            {t("esc.removeTier")}
          </button>
        </span>
      </div>
      <div className="row filters">
        <div
          className={`field${seconds === null || tooShort ? " invalid" : ""}`}
        >
          <label htmlFor={ids.after}>
            {index === 0 ? t("esc.afterFirst") : t("esc.after")}
          </label>
          <input
            id={ids.after}
            value={tier.after}
            placeholder="PT2H"
            aria-invalid={!isDuration(tier.after) || tooShort}
            onChange={(event) => {
              onChange({
                ...tier,
                after: event.target.value.trim().toUpperCase(),
              });
            }}
          />
          <span className="small muted">
            {seconds === null
              ? t("wf.durationHint")
              : tooShort
                ? t("esc.atLeastMinute")
                : humanDuration(seconds, locale)}
          </span>
        </div>
        <div className="field">
          <label htmlFor={ids.repeat}>{t("esc.repeat")}</label>
          <input
            id={ids.repeat}
            type="number"
            min={0}
            value={tier.repeat}
            onChange={(event) => {
              onChange({
                ...tier,
                repeat: Math.max(0, Number(event.target.value)),
              });
            }}
          />
        </div>
        <label className="inline" htmlFor={ids.skip}>
          <input
            id={ids.skip}
            type="checkbox"
            checked={tier.skip_if_empty}
            onChange={(event) => {
              onChange({ ...tier, skip_if_empty: event.target.checked });
            }}
          />
          {t("esc.skipIfEmpty")}
        </label>
      </div>
      <fieldset className="row">
        <legend>{t("esc.channels")}</legend>
        {channels.map((channel) => (
          <label key={channel} className="inline">
            <input
              type="checkbox"
              checked={chosen.includes(channel)}
              onChange={(event) => {
                const next: Channel[] = event.target.checked
                  ? [...chosen, channel]
                  : chosen.filter((item) => item !== channel);
                onChange({ ...tier, channels: next });
              }}
            />
            <ChannelLabel channel={channel} />
          </label>
        ))}
      </fieldset>
      <fieldset className="stack tight">
        <legend>{t("esc.responders")}</legend>
        {responders.map((responder, at) => (
          <ResponderRow
            key={at}
            responder={responder}
            index={at}
            onChange={(next) => {
              onChange({
                ...tier,
                add_responders: responders.map((item, i) =>
                  i === at ? next : item,
                ),
              });
            }}
            onRemove={() => {
              onChange({
                ...tier,
                add_responders: responders.filter((_item, i) => i !== at),
              });
            }}
          />
        ))}
        <span>
          <button
            type="button"
            onClick={() => {
              onChange({
                ...tier,
                add_responders: [...responders, { kind: "subscriber", id: "" }],
              });
            }}
          >
            {t("esc.addResponder")}
          </button>
        </span>
      </fieldset>
    </li>
  );
}

function newTier(): Tier {
  return { after: "PT1H", channels: [], repeat: 0, skip_if_empty: true };
}

function move<T>(items: readonly T[], from: number, to: number): T[] {
  const item = items[from];
  if (item === undefined || to < 0 || to >= items.length) return [...items];
  const without = items.filter((_value, index) => index !== from);
  return [...without.slice(0, to), item, ...without.slice(to)];
}

function clean(tier: Tier): Tier {
  const responders = (tier.add_responders ?? []).filter(
    (item) => item.id !== "",
  );
  return {
    after: tier.after,
    repeat: tier.repeat,
    skip_if_empty: tier.skip_if_empty,
    ...((tier.channels ?? []).length > 0 ? { channels: tier.channels } : {}),
    ...(responders.length > 0 ? { add_responders: responders } : {}),
  };
}

function PolicyUsage({ policyKey }: { policyKey: string }) {
  const { t } = useI18n();
  const usage = useGet<EscalationPolicyUsage>(
    `/v1/escalation_policies/${enc(policyKey)}/usage`,
  );
  if (usage.state.kind !== "ready")
    return usage.state.kind === "error" ? (
      <p className="small muted">{t("esc.usageUnavailable")}</p>
    ) : null;
  const open = usage.state.data.versions.filter(
    (row) => row.open + row.stalled > 0,
  );
  return (
    <Section title={t("esc.inUse")}>
      {open.length === 0 ? (
        <p className="muted">{t("esc.noWaitpoints")}</p>
      ) : (
        <ul className="plain" data-policy-usage>
          {open.map((row) => (
            <li key={row.version}>
              {t("esc.pinned", {
                version: row.version,
                open: row.open,
                stalled: row.stalled,
              })}
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}

function Versions({
  policyKey,
  refresh,
}: {
  policyKey: string;
  refresh: number;
}) {
  const { t } = useI18n();
  const columns: Column<PolicyVersion>[] = [
    {
      key: "version",
      header: t("wf.version"),
      render: (row) => `v${row.version}`,
    },
    { key: "tiers", header: t("esc.tiers"), render: (row) => row.tiers.length },
    {
      key: "description",
      header: t("wf.description"),
      render: (row) => row.description ?? "—",
    },
    {
      key: "created",
      header: t("activity.created"),
      render: (row) => <Time value={row.created_at} />,
    },
  ];
  return (
    <div key={refresh}>
      <PagedTable
        title={t("wf.versions")}
        path={`/v1/escalation_policies/${enc(policyKey)}/versions`}
        columns={columns}
        rowKey={(row) => String(row.version)}
      />
    </div>
  );
}

function PolicyForm({
  policyKey,
  existing,
}: {
  policyKey: string;
  existing: Policy | null;
}) {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const descriptionId = useId();
  const [policy, setPolicy] = useState(existing);
  const [tiers, setTiers] = useState<Tier[]>(existing?.tiers ?? [newTier()]);
  const [description, setDescription] = useState(existing?.description ?? "");
  const [dirty, setDirty] = useState(existing === null);
  const [message, setMessage] = useState<string | null>(null);
  const [errors, setErrors] = useState<string[]>([]);
  const [key, setKey] = useState(idempotencyKey);
  const [refresh, setRefresh] = useState(0);
  const valid = tiers.every((tier) => (durationSeconds(tier.after) ?? 0) >= 60);
  const update = (next: Tier[]) => {
    setTiers(next);
    setDirty(true);
    setMessage(null);
  };
  const save = () => {
    setErrors([]);
    mutate<Policy>(
      "PUT",
      `/v1/escalation_policies/${enc(policyKey)}`,
      {
        tiers: tiers.map(clean),
        ...(description.trim() === ""
          ? {}
          : { description: description.trim() }),
      },
      key,
      policy === null ? undefined : etag(policy.version),
    ).then(
      (saved) => {
        setKey(idempotencyKey());
        setPolicy(saved);
        setDirty(false);
        setRefresh((value) => value + 1);
        setMessage(t("esc.saved", { version: saved.version }));
      },
      (failure: unknown) => {
        if (stepUp(failure)) return;
        const fields =
          failure instanceof ApiError
            ? ((
                failure.problem as {
                  errors?: { pointer: string; code: string }[];
                } | null
              )?.errors ?? [])
            : [];
        setErrors(
          fields.length > 0
            ? fields.map((field) => `${field.pointer} ${field.code}`)
            : [problemText(failure)],
        );
      },
    );
  };
  return (
    <div className="stack">
      <div className="row">
        <Mono>{policyKey}</Mono>
        <span className="muted">
          {policy === null
            ? t("esc.unsaved")
            : t("esc.latest", { version: policy.version })}
        </span>
      </div>
      <div className="field">
        <label htmlFor={descriptionId}>{t("wf.description")}</label>
        <input
          id={descriptionId}
          value={description}
          onChange={(event) => {
            setDescription(event.target.value);
            setDirty(true);
          }}
        />
      </div>
      <Section title={t("esc.timeline")}>
        <Timeline tiers={tiers} />
      </Section>
      <ol className="plain stack tiers">
        {tiers.map((tier, index) => (
          <TierCard
            key={index}
            tier={tier}
            index={index}
            count={tiers.length}
            onChange={(next) => {
              update(tiers.map((item, at) => (at === index ? next : item)));
            }}
            onMove={(target) => {
              if (target === -1) update(move(tiers, index, index - 1));
              else if (target === -2) update(move(tiers, index, index + 1));
              else update(move(tiers, target, index));
            }}
            onRemove={() => {
              update(tiers.filter((_item, at) => at !== index));
            }}
          />
        ))}
      </ol>
      <div className="row toolbar">
        <button
          type="button"
          onClick={() => {
            update([...tiers, newTier()]);
          }}
        >
          {t("esc.addTier")}
        </button>
        <button
          type="button"
          className="primary"
          disabled={!dirty || !valid || tiers.length === 0}
          onClick={save}
        >
          {t("esc.save")}
        </button>
        {message !== null && <span role="status">{message}</span>}
      </div>
      {errors.length > 0 && (
        <ul role="alert" className="plain">
          {errors.map((error) => (
            <li key={error}>{error}</li>
          ))}
        </ul>
      )}
      {policy !== null && (
        <>
          <PolicyUsage policyKey={policyKey} />
          <Versions policyKey={policyKey} refresh={refresh} />
        </>
      )}
    </div>
  );
}

// AG-17
/** The visual escalation policy editor: tiers on a timeline, each with its wait, channels, added responders, repeats and skip rule; every save is a new immutable version. */
export function EscalationPolicyEditor({ policyKey }: { policyKey: string }) {
  const { t } = useI18n();
  const loaded = useGet<Policy>(`/v1/escalation_policies/${enc(policyKey)}`);
  return (
    <section className="stack">
      <p>
        <Link to="/escalation">{t("esc.back")}</Link>
      </p>
      <h1>{t("esc.policyTitle", { key: policyKey })}</h1>
      {loaded.state.kind === "error" &&
      loaded.state.error instanceof ApiError &&
      loaded.state.error.status === 404 ? (
        <PolicyForm policyKey={policyKey} existing={null} />
      ) : (
        <Loadable state={loaded.state} onRetry={loaded.reload}>
          {(policy) => <PolicyForm policyKey={policyKey} existing={policy} />}
        </Loadable>
      )}
    </section>
  );
}
