import { useGet, usePaged } from "../../api/hooks";
import type { Subscriber, TopicSubscription, Page } from "../../api/types";
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
import { maskField } from "../../components/mask";
import { useI18n } from "../../i18n/i18n";
import { Consents, Devices, Preferences, Profile } from "../why/Why";

// X-5
export function Recipients() {
  const { t } = useI18n();
  const paged = usePaged<Subscriber>("/v1/subscribers");
  const columns: Column<Subscriber>[] = [
    {
      key: "id",
      header: t("why.recipientId"),
      render: (row) => (
        <Link to={`/recipients/${encodeURIComponent(row.external_id)}`}>
          {row.external_id}
        </Link>
      ),
    },
    {
      key: "email",
      header: t("pii.field.email"),
      render: (row) => <Mono>{maskField("email", row.email) ?? "—"}</Mono>,
    },
    {
      key: "phone",
      header: t("pii.field.phone"),
      render: (row) => <Mono>{maskField("phone", row.phone) ?? "—"}</Mono>,
    },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
    {
      key: "updated",
      header: t("common.updated"),
      render: (row) => <Time value={row.updated_at} />,
    },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.recipients")}</h1>
      <p className="muted">{t("recipients.noExport")}</p>
      <Loadable state={paged.state} onRetry={paged.reload}>
        {() => (
          <DataTable
            caption={t("nav.recipients")}
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

function Subscriptions({ subscriber }: { subscriber: Subscriber }) {
  const { t } = useI18n();
  const subscriptions = useGet<Page<TopicSubscription>>(
    `/v1/subscribers/${encodeURIComponent(subscriber.external_id)}/subscriptions`,
    { limit: 100 },
  );
  const columns: Column<TopicSubscription>[] = [
    {
      key: "topic",
      header: t("nav.topics"),
      render: (row) => <Mono>{row.topic}</Mono>,
    },
    { key: "state", header: t("activity.state"), render: (row) => row.state },
    {
      key: "created",
      header: t("activity.created"),
      render: (row) => <Time value={row.created_at} />,
    },
  ];
  return (
    <Section title={t("recipients.subscriptions")}>
      <Loadable state={subscriptions.state} onRetry={subscriptions.reload}>
        {(page) => (
          <DataTable
            caption={t("recipients.subscriptions")}
            columns={columns}
            rows={page.data}
            rowKey={(row) => row.id}
          />
        )}
      </Loadable>
    </Section>
  );
}

export function RecipientDetail({ id }: { id: string }) {
  const { t } = useI18n();
  const subscriber = useGet<Subscriber>(
    `/v1/subscribers/${encodeURIComponent(id)}`,
  );
  return (
    <section className="stack">
      <p>
        <Link to="/recipients">{t("recipients.back")}</Link>
      </p>
      <h1>
        {t("nav.recipients")} <Mono>{id}</Mono>
      </h1>
      <Loadable state={subscriber.state} onRetry={subscriber.reload}>
        {(data) => (
          <div className="stack">
            <Profile subscriber={data} />
            <Devices subscriber={data} />
            <Subscriptions subscriber={data} />
            <Consents subscriber={data} />
            <Preferences subscriber={data} />
            <p>
              <Link to={`/why?recipient=${encodeURIComponent(id)}`}>
                {t("recipients.why")}
              </Link>
            </p>
          </div>
        )}
      </Loadable>
    </section>
  );
}
