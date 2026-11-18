import { useId, useState, type SyntheticEvent } from "react";
import { idempotencyKey } from "../../api/client";
import { useGet, useMutation } from "../../api/hooks";
import type { Page, ServerSchemas } from "../../api/types";
import { Link, useRouter } from "../../app/router";
import { Mono, Section, Time, type Column } from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { useI18n } from "../../i18n/i18n";
import { problemText } from "../../session/stepUp";
import { patterns } from "./model";

type Workflow = ServerSchemas["Workflow"];
type Category = ServerSchemas["Category"];

export function PublicationBadge({
  publication,
}: {
  publication: Workflow["last_publication"];
}) {
  const { t } = useI18n();
  if (publication === null || publication === undefined) return <>—</>;
  const tone =
    publication.status === "published"
      ? "ok"
      : publication.status === "rejected"
        ? "bad"
        : "warn";
  return (
    <span
      className={`badge tone-${tone}`}
      data-publication={publication.status}
    >
      <span className="badge-label">
        {t(`wf.publication.${publication.status}`)}
      </span>
    </span>
  );
}

function NewWorkflow() {
  const { t } = useI18n();
  const mutate = useMutation();
  const { navigate } = useRouter();
  const ids = { key: useId(), name: useId(), category: useId() };
  const categories = useGet<Page<Category>>("/v1/categories", { limit: 100 });
  const [form, setForm] = useState({ key: "", name: "", category: "" });
  const [error, setError] = useState<string | null>(null);
  const [key, setKey] = useState(idempotencyKey);
  const valid =
    patterns.slug.test(form.key) &&
    form.name.trim() !== "" &&
    form.category !== "";
  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(null);
    mutate<Workflow>(
      "POST",
      "/v1/workflows",
      {
        key: form.key,
        definition: {
          name: form.name.trim(),
          category: form.category,
          event_schema: { type: "object" },
          steps: [],
        },
      },
      key,
    ).then(
      (created) => {
        setKey(idempotencyKey());
        navigate(`/workflows/${encodeURIComponent(created.key)}`);
      },
      (failure: unknown) => {
        setError(problemText(failure));
      },
    );
  };
  const options =
    categories.state.kind === "ready"
      ? categories.state.data.data.filter((item) => item.enabled)
      : [];
  return (
    <Section title={t("wf.new")}>
      <form className="row filters" onSubmit={submit}>
        <div className="field">
          <label htmlFor={ids.key}>{t("wf.key")}</label>
          <input
            id={ids.key}
            value={form.key}
            required
            aria-invalid={form.key !== "" && !patterns.slug.test(form.key)}
            placeholder="order-shipped"
            onChange={(event) => {
              setForm({ ...form, key: event.target.value.trim() });
            }}
          />
        </div>
        <div className="field grow">
          <label htmlFor={ids.name}>{t("wf.name")}</label>
          <input
            id={ids.name}
            value={form.name}
            required
            onChange={(event) => {
              setForm({ ...form, name: event.target.value });
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.category}>{t("why.category")}</label>
          <select
            id={ids.category}
            value={form.category}
            required
            onChange={(event) => {
              setForm({ ...form, category: event.target.value });
            }}
          >
            <option value="">{t("wf.chooseCategory")}</option>
            {options.map((item) => (
              <option key={item.key} value={item.key}>
                {item.name} ({item.key})
              </option>
            ))}
          </select>
        </div>
        <button type="submit" className="primary" disabled={!valid}>
          {t("wf.create")}
        </button>
      </form>
      {error !== null && <p role="alert">{error}</p>}
    </Section>
  );
}

// X-8
// X-10
export function Workflows() {
  const { t } = useI18n();
  const columns: Column<Workflow>[] = [
    {
      key: "key",
      header: t("wf.key"),
      render: (row) => (
        <Link to={`/workflows/${encodeURIComponent(row.key)}`}>
          <Mono>{row.key}</Mono>
        </Link>
      ),
    },
    { key: "name", header: t("wf.name"), render: (row) => row.name },
    {
      key: "manager",
      header: t("wf.manager"),
      render: (row) => t(`wf.managedBy.${row.managed_by}`),
    },
    {
      key: "published",
      header: t("wf.live"),
      render: (row) =>
        row.published_version === null || row.published_version === undefined
          ? "—"
          : `v${row.published_version}`,
    },
    {
      key: "publication",
      header: t("wf.lastPublication"),
      render: (row) => <PublicationBadge publication={row.last_publication} />,
    },
    {
      key: "updated",
      header: t("common.updated"),
      render: (row) => <Time value={row.updated_at} />,
    },
  ];
  return (
    <section className="stack">
      <h1>{t("nav.workflows")}</h1>
      <p className="muted">{t("wf.intro")}</p>
      <PagedTable
        title={t("wf.list")}
        path="/v1/workflows"
        columns={columns}
        rowKey={(row) => row.id}
      />
      <NewWorkflow />
    </section>
  );
}
