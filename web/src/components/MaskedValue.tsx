import { useId, useState, type FormEvent } from "react";
import { ApiError, idempotencyKey, request } from "../api/client";
import type { RevealField, RevealResult } from "../api/types";
import { useRouter, href } from "../app/router";
import { useI18n } from "../i18n/i18n";
import { useRequestContext, useSession } from "../session/session";

type Phase =
  | { kind: "masked" }
  | { kind: "asking"; key: string }
  | { kind: "busy"; key: string }
  | { kind: "revealed"; value: string }
  | { kind: "step_up" }
  | { kind: "failed"; reason: string; key: string };

function show(value: unknown): string {
  if (value === null || value === undefined) return "—";
  return typeof value === "string" ? value : JSON.stringify(value);
}

// X-5
// X-3
/** A masked personal field; revealing it asks for a reason, may need step-up and is audited by the server. */
export function MaskedValue({
  subscriberId,
  field,
  masked,
}: {
  subscriberId: string;
  field: RevealField;
  masked: string | null;
}) {
  const { t } = useI18n();
  const { startStepUp } = useSession();
  const { location } = useRouter();
  const context = useRequestContext();
  const [phase, setPhase] = useState<Phase>({ kind: "masked" });
  const [reason, setReason] = useState("");
  const reasonId = useId();
  const fieldName = t(`pii.field.${field}`);

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (phase.kind !== "asking" && phase.kind !== "failed") return;
    const key = phase.key;
    setPhase({ kind: "busy", key });
    request<RevealResult>(
      "POST",
      `/v1/operator/subscribers/${encodeURIComponent(subscriberId)}/reveal`,
      { body: { fields: [field], reason }, idempotencyKey: key, context },
    ).then(
      (result) => {
        setReason("");
        setPhase({ kind: "revealed", value: show(result.fields[field]) });
      },
      (error: unknown) => {
        if (
          error instanceof ApiError &&
          error.code === "auth_step_up_required"
        ) {
          setPhase({ kind: "step_up" });
          const query = location.search.toString();
          const returnTo = href(location.path) + (query ? `?${query}` : "");
          void startStepUp(returnTo);
          return;
        }
        const detail =
          error instanceof ApiError
            ? (error.problem?.detail ?? error.message)
            : String(error);
        setPhase({ kind: "failed", reason: detail, key: idempotencyKey() });
      },
    );
  };

  if (phase.kind === "revealed") {
    return (
      <span className="row" data-pii="revealed">
        <span className="mono">{phase.value}</span>
        <button
          type="button"
          onClick={() => {
            setPhase({ kind: "masked" });
          }}
        >
          {t("pii.hide")}
        </button>
      </span>
    );
  }

  return (
    <div className="stack" data-pii="masked">
      <span className="row">
        <span className="mono">{masked ?? "—"}</span>
        <span className="visually-hidden">{t("pii.masked")}</span>
        {phase.kind === "masked" && masked !== null && (
          <button
            type="button"
            onClick={() => {
              setPhase({ kind: "asking", key: idempotencyKey() });
            }}
          >
            {t("pii.reveal")}
            <span className="visually-hidden"> {fieldName}</span>
          </button>
        )}
      </span>
      {phase.kind === "step_up" && (
        <span role="status" className="notice">
          {t("pii.stepUp")}
        </span>
      )}
      {(phase.kind === "asking" ||
        phase.kind === "busy" ||
        phase.kind === "failed") && (
        <form
          className="panel stack"
          onSubmit={submit}
          aria-label={t("pii.revealTitle", { field: fieldName })}
        >
          <p>{t("pii.revealBody")}</p>
          <label htmlFor={reasonId}>{t("pii.reason")}</label>
          <textarea
            id={reasonId}
            required
            maxLength={2000}
            value={reason}
            onChange={(event) => {
              setReason(event.target.value);
            }}
          />
          {phase.kind === "failed" && (
            <p role="alert">{t("pii.failed", { reason: phase.reason })}</p>
          )}
          <span className="row">
            <button
              type="submit"
              className="primary"
              disabled={phase.kind === "busy" || reason.trim() === ""}
            >
              {t("pii.confirm")}
            </button>
            <button
              type="button"
              onClick={() => {
                setPhase({ kind: "masked" });
              }}
            >
              {t("pii.cancel")}
            </button>
          </span>
        </form>
      )}
    </div>
  );
}
