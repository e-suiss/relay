import {
  useEffect,
  useId,
  useMemo,
  useState,
  type SyntheticEvent,
} from "react";
import { idempotencyKey } from "../../api/client";
import { useFetch, useGet, useMutation, usePaged } from "../../api/hooks";
import type {
  Channel,
  Notification,
  OperatorSchemas,
  Page,
  ServerSchemas,
} from "../../api/types";
import { Link } from "../../app/router";
import {
  DataTable,
  Loadable,
  Mono,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { ChannelPreview } from "../../components/preview/ChannelPreview";
import { RuleSentence } from "../../components/rule";
import { ChannelLabel } from "../../components/status";
import { useI18n } from "../../i18n/i18n";
import { problemText, useStepUp } from "../../session/stepUp";
import { formatMicros } from "../reports/Reports";

type WorkflowVersion = ServerSchemas["WorkflowVersion"];
type WorkflowPreview = ServerSchemas["WorkflowPreview"];
type PreviewSample = ServerSchemas["PreviewSample"];
type TestRecipient = ServerSchemas["TestRecipient"];
type EventAccepted = ServerSchemas["EventAccepted"];
type Campaign = ServerSchemas["Campaign"];
type SendModeSetting = OperatorSchemas["SendModeSetting"];

const enc = encodeURIComponent;

// X-11
function MermaidExport({
  workflowKey,
  version,
}: {
  workflowKey: string;
  version: number;
}) {
  const { t } = useI18n();
  const fetchText = useFetch();
  const [text, setText] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const download = useMemo(
    () =>
      text === null
        ? null
        : URL.createObjectURL(new Blob([text], { type: "text/plain" })),
    [text],
  );
  useEffect(
    () => () => {
      if (download !== null) URL.revokeObjectURL(download);
    },
    [download],
  );
  return (
    <div className="stack tight">
      <span className="row">
        <button
          type="button"
          onClick={() => {
            setError(null);
            fetchText<string>(
              `/v1/workflows/${enc(workflowKey)}/versions/${version}/mermaid`,
              "text/plain",
            ).then(setText, (failure: unknown) => {
              setError(problemText(failure));
            });
          }}
        >
          {t("wf.mermaid", { version })}
        </button>
        {download !== null && (
          <a
            className="button"
            href={download}
            download={`${workflowKey}-v${version}.mmd`}
          >
            {t("wf.downloadMermaid")}
          </a>
        )}
      </span>
      {error !== null && <p role="alert">{error}</p>}
      {text !== null && (
        <pre className="plain-text" tabIndex={0} data-mermaid={version}>
          {text}
        </pre>
      )}
    </div>
  );
}

// X-10
// X-11
/** The published versions; any earlier one republishes as a new version in one click, and each exports as Mermaid. */
export function VersionsPanel({
  workflowKey,
  published,
  onPromote,
}: {
  workflowKey: string;
  published: number | null;
  onPromote: (version: number) => void;
}) {
  const { t } = useI18n();
  const versions = useGet<Page<WorkflowVersion>>(
    `/v1/workflows/${enc(workflowKey)}/versions`,
    { limit: 50 },
  );
  const columns: Column<WorkflowVersion>[] = [
    {
      key: "version",
      header: t("wf.version"),
      render: (row) => (
        <span>
          v{row.version}
          {row.version === published && (
            <span className="badge tone-ok">
              <span className="badge-label">{t("wf.live")}</span>
            </span>
          )}
        </span>
      ),
    },
    {
      key: "from",
      header: t("wf.promotedFrom"),
      render: (row) =>
        row.promoted_from === null || row.promoted_from === undefined
          ? "—"
          : `v${row.promoted_from}`,
    },
    {
      key: "published",
      header: t("wf.publishedAt"),
      render: (row) => <Time value={row.published_at} />,
    },
    {
      key: "by",
      header: t("wf.publishedBy"),
      render: (row) => row.published_by ?? "—",
    },
    {
      key: "digest",
      header: t("wf.digest"),
      render: (row) => <Mono>{row.definition_digest.slice(0, 12)}</Mono>,
    },
    {
      key: "actions",
      header: t("common.actions"),
      render: (row) => (
        <div className="stack tight">
          {row.version !== published && (
            <span>
              <button
                type="button"
                data-promote={row.version}
                onClick={() => {
                  onPromote(row.version);
                }}
              >
                {t("wf.revert", { version: row.version })}
              </button>
            </span>
          )}
          <MermaidExport workflowKey={workflowKey} version={row.version} />
        </div>
      ),
    },
  ];
  return (
    <Section title={t("wf.versions")}>
      <p className="muted small">{t("wf.versionsIntro")}</p>
      <Loadable state={versions.state} onRetry={versions.reload}>
        {(page) => (
          <DataTable
            caption={t("wf.versions")}
            columns={columns}
            rows={page.data}
            rowKey={(row) => row.id}
          />
        )}
      </Loadable>
    </Section>
  );
}

// X-10
/** The notifications of this workflow with the version each one used. */
export function NotificationsPanel({ workflowKey }: { workflowKey: string }) {
  const { t } = useI18n();
  const columns: Column<Notification>[] = [
    {
      key: "created",
      header: t("activity.created"),
      render: (row) => (
        <Link to={`/activity/notifications/${enc(row.id)}`}>
          <Time value={row.created_at} />
        </Link>
      ),
    },
    {
      key: "version",
      header: t("wf.usedVersion"),
      render: (row) => <span data-used-version>v{row.workflow.version}</span>,
    },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
    {
      key: "plane",
      header: t("activity.plane"),
      render: (row) =>
        row.is_test ? t("activity.testSends") : t("activity.realSends"),
    },
  ];
  return (
    <PagedTable
      title={t("wf.notifications")}
      path="/v1/notifications"
      query={{ workflow: workflowKey }}
      columns={columns}
      rowKey={(row) => row.id}
    />
  );
}

// X-14
/** The audience preview of this workflow's campaigns: reachable recipients, sends by channel, drops by rule_id and the cost estimate. */
export function AudiencePanel({ workflowKey }: { workflowKey: string }) {
  const { t } = useI18n();
  const campaigns = usePaged<Campaign>("/v1/campaigns", {}, 100);
  const own = campaigns.items.filter(
    (item) => item.workflow.key === workflowKey,
  );
  return (
    <Section title={t("wf.audience")}>
      <p className="muted small">{t("wf.audienceIntro")}</p>
      <Loadable state={campaigns.state} onRetry={campaigns.reload}>
        {() =>
          own.length === 0 ? (
            <p className="muted" role="status">
              {t("wf.noCampaigns")}
            </p>
          ) : (
            <ul className="plain stack">
              {own.map((campaign) => (
                <li
                  key={campaign.id}
                  className="panel stack"
                  data-campaign={campaign.id}
                >
                  <div className="row">
                    <strong>{campaign.name}</strong>
                    <span className="muted">{campaign.state}</span>
                    <span className="small muted">
                      {t("wf.campaignAudience", {
                        count: campaign.audience.count,
                        expected: campaign.audience.expected_count,
                      })}
                    </span>
                  </div>
                  {campaign.preview === null ? (
                    <p className="small muted">{t("wf.previewNotReady")}</p>
                  ) : (
                    <AudiencePreview preview={campaign.preview} />
                  )}
                </li>
              ))}
            </ul>
          )
        }
      </Loadable>
    </Section>
  );
}

function AudiencePreview({
  preview,
}: {
  preview: NonNullable<Campaign["preview"]>;
}) {
  const { t } = useI18n();
  if (preview.state === "pending")
    return <p className="small muted">{t("wf.previewPending")}</p>;
  return (
    <div className="stack tight">
      <dl className="key-values">
        <div>
          <dt>{t("wf.evaluated")}</dt>
          <dd>{preview.evaluated}</dd>
        </div>
        <div>
          <dt>{t("wf.reachable")}</dt>
          <dd data-reachable>{preview.reachable}</dd>
        </div>
        {Object.entries(preview.sendable).map(([channel, count]) => (
          <div key={channel}>
            <dt>
              {t("wf.sendable")} · <ChannelLabel channel={channel as Channel} />
            </dt>
            <dd>{count}</dd>
          </div>
        ))}
      </dl>
      {preview.drops.length > 0 && (
        <ul className="plain">
          {preview.drops.map((drop) => (
            <li key={drop.rule_id} className="row">
              <RuleSentence ruleId={drop.rule_id} />
              <span>{t("wf.dropped", { count: drop.count })}</span>
            </li>
          ))}
        </ul>
      )}
      {preview.estimate !== null && (
        <ul className="plain small">
          {preview.estimate.channels.map((row) => (
            <li key={row.channel}>
              <ChannelLabel channel={row.channel} />:{" "}
              {row.cost_micros === null
                ? t("channels.notPriced")
                : formatMicros(String(row.cost_micros), row.currency)}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function resolveMode(
  settings: readonly SendModeSetting[],
  category: string,
  channel: Channel | null,
): SendModeSetting | null {
  const levels: ((row: SendModeSetting) => boolean)[] = [
    (row) =>
      row.level === "category_channel" &&
      row.category === category &&
      row.channel === channel,
    (row) => row.level === "channel" && row.channel === channel,
    (row) => row.level === "tenant",
    (row) => row.level === "installation",
  ];
  for (const level of levels) {
    const found = settings.find(level);
    if (found !== undefined) return found;
  }
  return null;
}

// X-15
/** The send mode that applies to each channel of this workflow, resolved from the category × channel, channel, tenant and installation levels. */
export function SendModePanel({
  category,
  channels,
}: {
  category: string;
  channels: readonly Channel[];
}) {
  const { t } = useI18n();
  const modes = useGet<OperatorSchemas["SendModeList"]>(
    "/v1/operator/send_modes",
  );
  const rows: (Channel | null)[] =
    channels.length === 0 ? [null] : [...channels];
  return (
    <Section title={t("wf.sendMode")}>
      <p className="muted small">{t("wf.sendModeIntro")}</p>
      <Loadable state={modes.state} onRetry={modes.reload}>
        {(list) => (
          <table>
            <caption className="visually-hidden">{t("wf.sendMode")}</caption>
            <thead>
              <tr>
                <th scope="col">{t("why.channel")}</th>
                <th scope="col">{t("wf.mode")}</th>
                <th scope="col">{t("wf.level")}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((channel) => {
                const found = resolveMode(list.data, category, channel);
                return (
                  <tr key={channel ?? "all"} data-send-mode={channel ?? "all"}>
                    <td>
                      {channel === null ? (
                        t("common.all")
                      ) : (
                        <ChannelLabel channel={channel} />
                      )}
                    </td>
                    <td>
                      {found === null ? "live" : found.mode}
                      {found !== null && found.mode !== "live" && (
                        <span className="small muted">
                          {" "}
                          {t(`wf.sendMode.${found.mode}`)}
                        </span>
                      )}
                    </td>
                    <td>
                      {found === null ? "—" : t(`wf.level.${found.level}`)}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </Loadable>
    </Section>
  );
}

const samples: readonly PreviewSample[] = [
  "schema_examples",
  "masked_recent",
  "boundary",
];

// TP-38
// X-10
/** Renders every step of the draft, the live version or a published version with sample data, for a subscriber or a recipient with no preferences. */
export function PreviewPanel({ workflowKey }: { workflowKey: string }) {
  const { t } = useI18n();
  const mutate = useMutation();
  const ids = {
    version: useId(),
    sample: useId(),
    to: useId(),
    locale: useId(),
  };
  const [form, setForm] = useState({
    version: "draft",
    sample: "schema_examples" as PreviewSample,
    to: "",
    locale: "",
  });
  const [result, setResult] = useState<WorkflowPreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    const version = /^\d+$/.test(form.version)
      ? Number(form.version)
      : form.version;
    mutate<WorkflowPreview>(
      "POST",
      `/v1/workflows/${enc(workflowKey)}/preview`,
      {
        version,
        sample: form.sample,
        ...(form.to === "" ? {} : { to: form.to }),
        ...(form.locale === "" ? {} : { locale: form.locale }),
      },
      idempotencyKey(),
    ).then(
      (preview) => {
        setBusy(false);
        setResult(preview);
      },
      (failure: unknown) => {
        setBusy(false);
        setError(problemText(failure));
      },
    );
  };
  return (
    <Section title={t("wf.preview")}>
      <form className="row filters" onSubmit={submit}>
        <div className="field">
          <label htmlFor={ids.version}>{t("wf.version")}</label>
          <input
            id={ids.version}
            value={form.version}
            size={8}
            onChange={(event) => {
              setForm({ ...form, version: event.target.value });
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.sample}>{t("wf.sample")}</label>
          <select
            id={ids.sample}
            value={form.sample}
            onChange={(event) => {
              setForm({ ...form, sample: event.target.value as PreviewSample });
            }}
          >
            {samples.map((sample) => (
              <option key={sample} value={sample}>
                {t(`wf.sample.${sample}`)}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor={ids.to}>{t("wf.previewTo")}</label>
          <input
            id={ids.to}
            value={form.to}
            onChange={(event) => {
              setForm({ ...form, to: event.target.value });
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.locale}>{t("why.locale")}</label>
          <input
            id={ids.locale}
            value={form.locale}
            placeholder="tr-TR"
            size={8}
            onChange={(event) => {
              setForm({ ...form, locale: event.target.value });
            }}
          />
        </div>
        <button type="submit" className="primary" disabled={busy}>
          {t("wf.runPreview")}
        </button>
      </form>
      <p className="small muted">{t("wf.previewVersionHint")}</p>
      {error !== null && <p role="alert">{error}</p>}
      {result !== null && (
        <ol className="plain stack" data-preview-result>
          {result.steps.map((step) => (
            <li key={step.step} className="stack tight">
              <div className="row">
                <code className="mono">{step.step}</code>
                <ChannelLabel channel={step.channel} />
                <Mono>{step.template}</Mono>
                <span
                  className={`badge tone-${step.would_send ? "ok" : "neutral"}`}
                >
                  <span className="badge-label">
                    {step.would_send ? t("wf.wouldSend") : t("wf.wouldSkip")}
                  </span>
                </span>
                {step.rule_id !== null && (
                  <RuleSentence ruleId={step.rule_id} />
                )}
              </div>
              {step.render !== null && <ChannelPreview render={step.render} />}
            </li>
          ))}
        </ol>
      )}
    </Section>
  );
}

// X-10
/** Sends the published version to up to five verified test recipients; the sends are marked as tests. */
export function TestSendPanel({
  workflowKey,
  published,
}: {
  workflowKey: string;
  published: number | null;
}) {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const dataId = useId();
  const recipients = useGet<Page<TestRecipient>>("/v1/test_recipients");
  const [chosen, setChosen] = useState<string[]>([]);
  const [data, setData] = useState("{}");
  const [key, setKey] = useState(idempotencyKey);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  let parsed: unknown = null;
  let invalid = false;
  try {
    parsed = JSON.parse(data);
  } catch {
    invalid = true;
  }
  const send = () => {
    setError(null);
    mutate<EventAccepted>(
      "POST",
      `/v1/workflows/${enc(workflowKey)}/test`,
      { to: chosen, data: parsed },
      key,
    ).then(
      (accepted) => {
        setKey(idempotencyKey());
        setMessage(
          t("wf.testSent", {
            event: accepted.id,
            count: accepted.recipient_count,
          }),
        );
      },
      (failure: unknown) => {
        if (!stepUp(failure)) setError(problemText(failure));
      },
    );
  };
  return (
    <Section title={t("wf.testSend")}>
      {published === null ? (
        <p className="muted">{t("wf.testNeedsPublished")}</p>
      ) : (
        <Loadable state={recipients.state} onRetry={recipients.reload}>
          {(page) => {
            const verified = page.data.filter(
              (row) => row.state === "verified",
            );
            return (
              <div className="stack">
                {verified.length === 0 ? (
                  <p className="muted">{t("wf.noTestRecipients")}</p>
                ) : (
                  <fieldset className="row">
                    <legend>{t("wf.testRecipients")}</legend>
                    {verified.map((row) => (
                      <label key={row.id} className="inline">
                        <input
                          type="checkbox"
                          checked={chosen.includes(row.id)}
                          disabled={
                            !chosen.includes(row.id) && chosen.length >= 5
                          }
                          onChange={(event) => {
                            setChosen(
                              event.target.checked
                                ? [...chosen, row.id]
                                : chosen.filter((id) => id !== row.id),
                            );
                          }}
                        />
                        {row.subscriber_id ?? row.id}
                        {row.device_id !== null && ` · ${row.device_id}`}
                      </label>
                    ))}
                  </fieldset>
                )}
                <div className="field">
                  <label htmlFor={dataId}>{t("wf.testData")}</label>
                  <textarea
                    id={dataId}
                    rows={4}
                    value={data}
                    aria-invalid={invalid}
                    className="mono"
                    onChange={(event) => {
                      setData(event.target.value);
                    }}
                  />
                </div>
                <span>
                  <button
                    type="button"
                    className="primary"
                    disabled={chosen.length === 0 || invalid}
                    onClick={send}
                  >
                    {t("wf.sendTest", { version: published })}
                  </button>
                </span>
                {message !== null && <p role="status">{message}</p>}
                {error !== null && <p role="alert">{error}</p>}
              </div>
            );
          }}
        </Loadable>
      )}
    </Section>
  );
}
