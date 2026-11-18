import { useId, useState, type SyntheticEvent } from "react";
import type { Environment } from "../api/types";
import { useI18n } from "../i18n/i18n";
import { subtenantPattern, useSession } from "../session/session";

// X-4
export function ContextBar() {
  const { t } = useI18n();
  const { context, tenants, setContext } = useSession();
  const tenantId = useId();
  const environmentId = useId();
  const subtenantId = useId();
  const hintId = useId();
  const [draft, setDraft] = useState<string | null>(null);
  const value = draft ?? context.subtenant ?? "";
  const invalid = value !== "" && !subtenantPattern.test(value);
  const choice = tenants.find((item) => item.tenant === context.tenant);

  const apply = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (invalid) return;
    setContext({ subtenant: value === "" ? null : value });
    setDraft(null);
  };

  if (tenants.length === 0) {
    return (
      <p className="muted" role="status">
        {t("context.none")}
      </p>
    );
  }

  return (
    <form
      className={
        context.environment === "test" ? "context-bar env-test" : "context-bar"
      }
      aria-label={t("context.label")}
      onSubmit={apply}
    >
      <div className="field">
        <label htmlFor={tenantId}>{t("context.tenant")}</label>
        <select
          id={tenantId}
          value={context.tenant ?? ""}
          onChange={(event) => {
            setContext({ tenant: event.target.value });
          }}
        >
          {tenants.map((item) => (
            <option key={item.tenant} value={item.tenant}>
              {item.tenant}
            </option>
          ))}
        </select>
      </div>
      <div className="field">
        <label htmlFor={environmentId}>{t("context.environment")}</label>
        <select
          id={environmentId}
          value={context.environment}
          onChange={(event) => {
            setContext({ environment: event.target.value as Environment });
          }}
        >
          {(choice?.environments ?? []).map((env) => (
            <option key={env} value={env}>
              {t(`env.${env}`)}
            </option>
          ))}
        </select>
      </div>
      <div className="field">
        <label htmlFor={subtenantId}>{t("context.subtenant")}</label>
        <input
          id={subtenantId}
          value={value}
          placeholder={t("context.subtenantAll")}
          aria-describedby={hintId}
          aria-invalid={invalid}
          spellCheck={false}
          autoComplete="off"
          onChange={(event) => {
            setDraft(event.target.value.trim());
          }}
        />
      </div>
      <span id={hintId} className="visually-hidden">
        {invalid ? t("context.subtenantInvalid") : t("context.subtenantHint")}
      </span>
      <button type="submit" disabled={invalid}>
        {t("context.apply")}
      </button>
    </form>
  );
}
