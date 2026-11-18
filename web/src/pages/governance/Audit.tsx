import { useId, useState, type SyntheticEvent } from "react";
import { usePaged } from "../../api/hooks";
import type { OperatorSchemas } from "../../api/types";
import {
  DataTable,
  Dash,
  Loadable,
  Mono,
  Pager,
  Time,
  type Column,
} from "../../components/data";
import { useI18n } from "../../i18n/i18n";

type AuditRecord = OperatorSchemas["AuditRecord"];

// X-5
export function Audit() {
  const { t } = useI18n();
  const actionId = useId();
  const [draft, setDraft] = useState("");
  const [action, setAction] = useState("");
  const paged = usePaged<AuditRecord>("/v1/operator/audit_log", { action });

  const apply = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    setAction(draft.trim());
  };

  const columns: Column<AuditRecord>[] = [
    {
      key: "time",
      header: t("history.occurred"),
      render: (row) => <Time value={row.created_at} />,
    },
    {
      key: "action",
      header: t("audit.action"),
      render: (row) => <Mono>{row.action}</Mono>,
    },
    {
      key: "actor",
      header: t("audit.actor"),
      render: (row) => (
        <span>
          {t(`audit.actorKind.${row.actor_kind}`)} <Mono>{row.actor_ref}</Mono>
        </span>
      ),
    },
    {
      key: "target",
      header: t("audit.target"),
      render: (row) =>
        row.target_id ? (
          <Mono>
            {row.target_type ?? ""} {row.target_id}
          </Mono>
        ) : (
          "—"
        ),
    },
    {
      key: "reason",
      header: t("pii.reason"),
      render: (row) => <Dash value={row.reason} />,
    },
  ];

  return (
    <section className="stack">
      <h1>{t("nav.audit")}</h1>
      <form className="row filters" onSubmit={apply}>
        <div className="field">
          <label htmlFor={actionId}>{t("audit.action")}</label>
          <input
            id={actionId}
            value={draft}
            placeholder="pii.revealed"
            onChange={(event) => {
              setDraft(event.target.value);
            }}
          />
        </div>
        <button type="submit" className="primary">
          {t("common.filter")}
        </button>
      </form>
      <Loadable state={paged.state} onRetry={paged.reload}>
        {() => (
          <DataTable
            caption={t("nav.audit")}
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
