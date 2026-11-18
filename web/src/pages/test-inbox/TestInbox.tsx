import { useState } from "react";
import { idempotencyKey } from "../../api/client";
import { useGet, useMutation, usePaged } from "../../api/hooks";
import type {
  ChannelRender,
  SeedRecipient,
  SeedReset,
  TestInboxDelivery,
  TestInboxMessage,
} from "../../api/pending";
import type { Page, ServerSchemas } from "../../api/types";
import { Link } from "../../app/router";
import {
  DataTable,
  Loadable,
  Mono,
  Pager,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { ChannelPreview } from "../../components/preview/ChannelPreview";
import { RuleSentence } from "../../components/rule";
import { ChannelLabel, StatusBadge } from "../../components/status";
import { useI18n } from "../../i18n/i18n";
import { useSession } from "../../session/session";
import { problemText, useStepUp } from "../../session/stepUp";

type SimulatedResult = ServerSchemas["SimulatedResult"];

// X-43
function Seeds() {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const seeds = useGet<Page<SeedRecipient>>("/v1/test/seed-recipients");
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [key, setKey] = useState(idempotencyKey);
  const [busy, setBusy] = useState(false);
  const columns: Column<SeedRecipient>[] = [
    {
      key: "id",
      header: t("ti.seed"),
      render: (row) => (
        <Link to={`/recipients/${encodeURIComponent(row.external_id)}`}>
          <Mono>{row.external_id}</Mono>
        </Link>
      ),
    },
    {
      key: "profile",
      header: t("ti.profile"),
      render: (row) => t(`ti.seedProfile.${row.external_id}`),
    },
    { key: "email", header: t("ti.email"), render: (row) => <Mono>{row.email}</Mono> },
    { key: "phone", header: t("ti.phone"), render: (row) => <Mono>{row.phone}</Mono> },
    {
      key: "result",
      header: t("ti.emailResult"),
      render: (row) => row.email_result,
    },
    {
      key: "setup",
      header: t("ti.setUp"),
      render: (row) => (row.set_up ? t("common.yes") : t("ti.pendingSetup")),
    },
  ];
  const reset = () => {
    setBusy(true);
    setError(null);
    mutate<SeedReset>("POST", "/v1/test/seed-recipients/reset", undefined, key).then(
      () => {
        setBusy(false);
        setKey(idempotencyKey());
        setMessage(t("ti.resetQueued"));
        seeds.reload();
      },
      (failure: unknown) => {
        setBusy(false);
        if (!stepUp(failure)) setError(problemText(failure));
      },
    );
  };
  return (
    <Section
      title={t("ti.seeds")}
      actions={
        <button type="button" disabled={busy} onClick={reset} data-reset-seeds>
          {t("ti.reset")}
        </button>
      }
    >
      <p className="muted small">{t("ti.seedsIntro")}</p>
      {message !== null && <p role="status">{message}</p>}
      {error !== null && <p role="alert">{error}</p>}
      <Loadable state={seeds.state} onRetry={seeds.reload}>
        {(page) => (
          <DataTable
            caption={t("ti.seeds")}
            columns={columns}
            rows={page.data}
            rowKey={(row) => row.external_id}
          />
        )}
      </Loadable>
    </Section>
  );
}

function Simulated() {
  const { t } = useI18n();
  const results = useGet<Page<SimulatedResult>>("/v1/test/simulated-results");
  const columns: Column<SimulatedResult>[] = [
    { key: "result", header: t("ti.result"), render: (row) => <Mono>{row.result}</Mono> },
    { key: "email", header: t("ti.email"), render: (row) => <Mono>{row.email}</Mono> },
    { key: "phone", header: t("ti.phone"), render: (row) => <Mono>{row.phone}</Mono> },
    { key: "token", header: t("ti.token"), render: (row) => <Mono>{row.token}</Mono> },
    {
      key: "description",
      header: t("wf.description"),
      render: (row) => row.description,
    },
  ];
  return (
    <Section title={t("ti.simulated")}>
      <details>
        <summary>{t("ti.simulatedIntro")}</summary>
        <Loadable state={results.state} onRetry={results.reload}>
          {(page) => (
            <DataTable
              caption={t("ti.simulated")}
              columns={columns}
              rows={page.data}
              rowKey={(row) => row.result}
            />
          )}
        </Loadable>
      </details>
    </Section>
  );
}

function renderOf(delivery: TestInboxDelivery): ChannelRender | null {
  const render = delivery.render;
  if (render === null || render.output === null) return null;
  return {
    channel: delivery.channel,
    locale: render.locale ?? "",
    content: render.output as ChannelRender["content"],
    warnings: [],
  };
}

// X-52
function DeliveryView({ delivery }: { delivery: TestInboxDelivery }) {
  const { t } = useI18n();
  const last = delivery.decisions.at(-1);
  const render = renderOf(delivery);
  return (
    <li className="stack tight delivery" data-test-delivery={delivery.delivery_id}>
      <div className="row">
        <ChannelLabel channel={delivery.channel} />
        <StatusBadge status={delivery.status} channel={delivery.channel} />
        <span className="small muted">{t(`why.gate.${delivery.gates}`)}</span>
        <RuleSentence
          ruleId={delivery.rule_id ?? last?.rule_id ?? null}
          description={last?.description ?? null}
        />
      </div>
      {delivery.render?.digest_only !== null &&
        delivery.render?.digest_only !== undefined && (
          <p className="notice small" data-digest-only={delivery.render.digest_only}>
            {t(`ti.digestOnly.${delivery.render.digest_only}`)}{" "}
            <Mono>{delivery.render.content_digest.slice(0, 16)}</Mono>
          </p>
        )}
      {render !== null && (
        <>
          {delivery.channel === "email" && (
            <p className="small muted">{t("ti.emailHtmlSandboxOnly")}</p>
          )}
          <ChannelPreview render={render} />
        </>
      )}
    </li>
  );
}

function Messages() {
  const { t } = useI18n();
  const paged = usePaged<TestInboxMessage>("/v1/test/inbox");
  return (
    <Section title={t("ti.messages")}>
      <Loadable state={paged.state} onRetry={paged.reload}>
        {() =>
          paged.items.length === 0 ? (
            <p className="muted" role="status">
              {t("ti.empty")}
            </p>
          ) : (
            <ul className="plain stack">
              {paged.items.map((message) => (
                <li
                  key={message.notification_id}
                  className="panel stack"
                  data-test-message={message.notification_id}
                >
                  <div className="row">
                    <Link
                      to={`/activity/notifications/${encodeURIComponent(message.notification_id)}`}
                    >
                      <Time value={message.created_at} />
                    </Link>
                    <Mono>{message.workflow.key}</Mono>
                    <span>v{message.workflow.version}</span>
                    <Mono>{message.recipient_id}</Mono>
                    <span className="muted">{message.state}</span>
                    {message.close_rule_id !== null &&
                      message.close_rule_id !== undefined && (
                        <RuleSentence ruleId={message.close_rule_id} />
                      )}
                  </div>
                  <ul className="plain stack">
                    {message.deliveries.map((delivery) => (
                      <DeliveryView key={delivery.delivery_id} delivery={delivery} />
                    ))}
                  </ul>
                </li>
              ))}
            </ul>
          )
        }
      </Loadable>
      <Pager
        hasPrevious={paged.hasPrevious}
        hasNext={paged.hasNext}
        onPrevious={paged.previous}
        onNext={paged.next}
      />
    </Section>
  );
}

// X-26
// X-43
// X-52
/** The test inbox: every test plane message as it was rendered, with its decisions; the seed recipients with their reset; and the fake provider's result table. */
export function TestInbox() {
  const { t } = useI18n();
  const { context } = useSession();
  return (
    <section className="stack">
      <h1>{t("nav.testInbox")}</h1>
      <p className="muted">{t("ti.intro")}</p>
      {context.environment === "test" ? (
        <>
          <Messages />
          <Seeds />
          <Simulated />
        </>
      ) : (
        <p className="notice" role="note" data-live-plane>
          {t("ti.liveOnly")}
        </p>
      )}
    </section>
  );
}
