import { RelayApiError } from "@esuiss/relay/browser";
import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import { RelayRoot, useRelay } from "../context.js";
import type { MessageKey } from "../i18n/index.js";
import { glyphs, StatusGlyph } from "../icons.js";
import {
  httpsUrl,
  messageStates,
  PortalApi,
  type MessageFilter,
  type PortalAttempt,
  type PortalEndpoint,
  type PortalEventType,
  type PortalHealth,
  type PortalMessage,
} from "./api.js";

/** Props of {@link WebhookPortal}. */
export interface WebhookPortalProps {
  readonly headingLevel?: 2 | 3;
}

type Flash = { readonly error: boolean; readonly text: string } | null;

function stateGlyph(state: string): string {
  if (state === "active" || state === "delivered") return glyphs.done;
  if (
    state === "disabled" ||
    state === "archived" ||
    state === "failed_permanent" ||
    state === "exhausted"
  )
    return glyphs.off;
  if (state === "paused" || state === "held") return glyphs.stopped;
  return glyphs.pending;
}

function EndpointForm({
  api,
  eventTypes,
  endpoint,
  onDone,
  onCancel,
}: {
  readonly api: PortalApi;
  readonly eventTypes: readonly PortalEventType[];
  readonly endpoint: PortalEndpoint | null;
  readonly onDone: (endpoint: PortalEndpoint, message: string) => void;
  readonly onCancel: () => void;
}): ReactNode {
  const { t } = useRelay();
  const [url, setUrl] = useState(endpoint?.destination.url ?? "");
  const [description, setDescription] = useState(endpoint?.description ?? "");
  const [selected, setSelected] = useState<ReadonlySet<string>>(
    new Set(endpoint?.event_types ?? []),
  );
  const [urlError, setUrlError] = useState<string | null>(null);
  const [typesError, setTypesError] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const urlId = useId();
  const urlHintId = useId();
  const urlErrorId = useId();
  const typesId = useId();

  const submit = (event: FormEvent) => {
    event.preventDefault();
    const trimmed = url.trim();
    const okUrl = httpsUrl(trimmed);
    setUrlError(okUrl ? null : t("portal.urlInvalid"));
    setTypesError(selected.size === 0);
    if (!okUrl || selected.size === 0) return;
    setBusy(true);
    setFormError(null);
    const types = [...selected];
    const request =
      endpoint === null
        ? api.create({
            url: trimmed,
            event_types: types,
            ...(description.trim() === "" ? {} : { description: description.trim() }),
          })
        : api.update(endpoint.id, {
            url: trimmed,
            event_types: types,
            description: description.trim() === "" ? null : description.trim(),
          });
    request
      .then((result) => onDone(result, t("common.saved")))
      .catch((error: unknown) => {
        if (error instanceof RelayApiError && error.code === "webhook_endpoint_url_not_allowed") {
          const reason = error.fieldErrors[0]?.detail ?? error.problem?.detail;
          setUrlError(
            reason === undefined
              ? t("portal.urlNotAllowedGeneric")
              : t("portal.urlNotAllowed", { reason }),
          );
        } else if (
          error instanceof RelayApiError &&
          error.code === "webhook_endpoint_limit_reached"
        ) {
          setFormError(t("portal.limitReached"));
        } else {
          setFormError(t("common.error"));
        }
      })
      .finally(() => setBusy(false));
  };

  const toggle = (name: string) =>
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });

  return (
    <form className="relay-card" onSubmit={submit} noValidate data-testid="relay-endpoint-form">
      <h3 className="relay-subheading">
        {endpoint === null ? t("portal.addEndpoint") : t("portal.editEndpoint")}
      </h3>
      <div className="relay-field">
        <label htmlFor={urlId}>{t("portal.url")}</label>
        <input
          id={urlId}
          className="relay-input"
          type="url"
          inputMode="url"
          autoComplete="url"
          value={url}
          onChange={(event) => setUrl(event.target.value)}
          aria-invalid={urlError !== null}
          aria-describedby={urlError === null ? urlHintId : `${urlHintId} ${urlErrorId}`}
          required
        />
        <span className="relay-muted" id={urlHintId}>
          {t("portal.urlHint")}
        </span>
        {urlError === null ? null : (
          <span className="relay-error" id={urlErrorId} role="alert" data-testid="relay-url-error">
            {urlError}
          </span>
        )}
      </div>
      <div className="relay-field">
        <label htmlFor={`${urlId}-description`}>{t("portal.description")}</label>
        <input
          id={`${urlId}-description`}
          className="relay-input"
          type="text"
          value={description}
          onChange={(event) => setDescription(event.target.value)}
        />
      </div>
      <fieldset className="relay-field" aria-describedby={typesError ? typesId : undefined}>
        <legend className="relay-label">{t("portal.eventTypes")}</legend>
        {eventTypes.length === 0 ? (
          <p className="relay-muted">{t("portal.eventTypesEmpty")}</p>
        ) : (
          <ul className="relay-checklist">
            {endpoint?.event_types.includes("*") === true ? (
              <li>
                <label>
                  <input type="checkbox" checked={selected.has("*")} onChange={() => toggle("*")} />
                  {t("portal.allEventTypes")}
                </label>
              </li>
            ) : null}
            {eventTypes.map((type) => (
              <li key={type.id}>
                <label>
                  <input
                    type="checkbox"
                    checked={selected.has(type.name)}
                    onChange={() => toggle(type.name)}
                  />
                  <span>
                    <span className="relay-code">{type.name}</span>
                    {type.description === null ? null : (
                      <span className="relay-muted"> {type.description}</span>
                    )}
                  </span>
                </label>
              </li>
            ))}
          </ul>
        )}
        {typesError ? (
          <span className="relay-error" id={typesId} role="alert">
            {t("portal.eventTypesRequired")}
          </span>
        ) : null}
      </fieldset>
      {formError === null ? null : (
        <p className="relay-error" role="alert">
          {formError}
        </p>
      )}
      <div className="relay-row">
        <button type="submit" className="relay-button relay-button-primary" aria-disabled={busy}>
          {t("common.save")}
        </button>
        <button type="button" className="relay-button" onClick={onCancel}>
          {t("common.cancel")}
        </button>
      </div>
    </form>
  );
}

function HealthPanel({ health }: { readonly health: PortalHealth }): ReactNode {
  const { t, formatTime } = useRelay();
  return (
    <div className="relay-stack" data-testid="relay-endpoint-health">
      <p>
        {health.success_rate_bp === null
          ? t("portal.noAttempts")
          : t("portal.successRate", { rate: `${(health.success_rate_bp / 100).toFixed(1)}%` })}
      </p>
      {health.latency_ms === null ? null : (
        <p>{t("portal.latency", { ms: health.latency_ms.p95 })}</p>
      )}
      <p>
        {t("portal.lastSuccess", {
          time:
            health.last_success_at === null
              ? t("common.never")
              : formatTime(health.last_success_at),
        })}
      </p>
      {health.failing_since === null ? null : (
        <p className="relay-status">
          <StatusGlyph glyph={glyphs.warning} />
          {t("portal.failingSince", { time: formatTime(health.failing_since) })}
        </p>
      )}
      {health.disable_at === null ? null : (
        <p>{t("portal.disableAt", { time: formatTime(health.disable_at) })}</p>
      )}
      <p>{t("portal.backlog", { waiting: health.backlog.waiting, held: health.backlog.held })}</p>
      <p>
        {t("portal.breaker", { state: t(`portal.breaker.${health.breaker.state}` as MessageKey) })}
      </p>
      {health.recent_failures.length === 0 ? null : (
        <>
          <p className="relay-label">{t("portal.recentFailures")}</p>
          <ul>
            {health.recent_failures.map((failure) => (
              <li key={failure.code}>
                {t("portal.failure", {
                  code: failure.code,
                  count: failure.count,
                  time: formatTime(failure.last_at),
                })}
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}

function EndpointCard({
  api,
  endpoint,
  onChanged,
  onEdit,
  flash,
}: {
  readonly api: PortalApi;
  readonly endpoint: PortalEndpoint;
  readonly onChanged: (endpoint: PortalEndpoint) => void;
  readonly onEdit: (endpoint: PortalEndpoint) => void;
  readonly flash: (flash: Flash) => void;
}): ReactNode {
  const { t, formatTime } = useRelay();
  const [health, setHealth] = useState<PortalHealth | null>(null);
  const [showHealth, setShowHealth] = useState(false);
  const [secret, setSecret] = useState<string | null>(null);
  const [since, setSince] = useState("");
  const [until, setUntil] = useState("");
  const healthId = useId();
  const recoverId = useId();
  const managed = endpoint.managed_by === "product";
  const url = endpoint.destination.url ?? endpoint.destination.kind ?? endpoint.id;
  const activeKey = endpoint.signing_keys.find((key) => key.state === "active") ?? null;

  const fail = () => flash({ error: true, text: t("common.error") });
  const toggleHealth = () => {
    const next = !showHealth;
    setShowHealth(next);
    if (next) api.health(endpoint.id).then(setHealth).catch(fail);
  };
  const setState = (state: "active" | "disabled") =>
    api.update(endpoint.id, { state }).then(onChanged).catch(fail);
  const rotate = () =>
    api
      .rotate(endpoint.id)
      .then((result) => {
        setSecret(result.secret);
        onChanged(result);
        flash({
          error: false,
          text: t("portal.rotated", {
            time:
              result.previous_key_expires_at === null
                ? t("common.never")
                : formatTime(result.previous_key_expires_at),
          }),
        });
      })
      .catch(fail);
  const test = () =>
    api
      .test(endpoint.id)
      .then(() => flash({ error: false, text: t("portal.testSent") }))
      .catch(fail);
  const archive = () => api.archive(endpoint.id).then(onChanged).catch(fail);
  const recover = (event: FormEvent) => {
    event.preventDefault();
    const from = Date.parse(since);
    if (Number.isNaN(from)) return;
    const to = until === "" ? undefined : Date.parse(until);
    api
      .recover(
        endpoint.id,
        new Date(from).toISOString(),
        to === undefined || Number.isNaN(to) ? undefined : new Date(to).toISOString(),
      )
      .then((result) =>
        flash({ error: false, text: t("portal.recovered", { count: result.selected }) }),
      )
      .catch(fail);
  };

  return (
    <li className="relay-card" data-testid="relay-endpoint">
      <p className="relay-code">{url}</p>
      {endpoint.description === null ? null : <p>{endpoint.description}</p>}
      <p className="relay-status">
        <StatusGlyph glyph={stateGlyph(endpoint.state)} />
        {t("portal.state", { state: t(`portal.state.${endpoint.state}` as MessageKey) })}
      </p>
      {endpoint.disabled_reason === null ? null : (
        <p data-testid="relay-disabled-reason">
          {t("portal.disabledReason", {
            reason: t(`portal.disabledReason.${endpoint.disabled_reason}` as MessageKey),
          })}
        </p>
      )}
      <p className="relay-muted">
        {t("portal.eventTypes")}:{" "}
        {endpoint.event_types
          .map((type) => (type === "*" ? t("portal.allEventTypes") : type))
          .join(", ")}
      </p>
      {activeKey === null || activeKey.public_key === null ? null : (
        <p>
          <span className="relay-label">{t("portal.publicKey")}: </span>
          <span className="relay-code">{activeKey.public_key}</span>
        </p>
      )}
      {secret === null ? null : (
        <div className="relay-notice" role="alert">
          <span>{t("portal.secretOnce")}</span>
          <span className="relay-label">{t("portal.secretLabel")}: </span>
          <span className="relay-code">{secret}</span>
          <button
            type="button"
            className="relay-button relay-button-small"
            onClick={() => setSecret(null)}
          >
            {t("common.close")}
          </button>
        </div>
      )}
      {endpoint.state === "archived" ? null : (
        <div className="relay-row">
          {managed ? null : (
            <button
              type="button"
              className="relay-button relay-button-small"
              onClick={() => onEdit(endpoint)}
            >
              {t("portal.edit")}
            </button>
          )}
          {managed ? null : endpoint.state === "disabled" ? (
            <button
              type="button"
              className="relay-button relay-button-small"
              onClick={() => void setState("active")}
            >
              {t("portal.enable")}
            </button>
          ) : (
            <button
              type="button"
              className="relay-button relay-button-small"
              onClick={() => void setState("disabled")}
            >
              {t("portal.disable")}
            </button>
          )}
          <button
            type="button"
            className="relay-button relay-button-small"
            onClick={() => void rotate()}
          >
            {t("portal.rotate")}
          </button>
          <button
            type="button"
            className="relay-button relay-button-small"
            onClick={() => void test()}
          >
            {t("portal.test")}
          </button>
          <button
            type="button"
            className="relay-button relay-button-small"
            aria-expanded={showHealth}
            aria-controls={healthId}
            onClick={toggleHealth}
          >
            {t("portal.health")}
          </button>
          {managed ? null : (
            <button
              type="button"
              className="relay-button relay-button-small"
              onClick={() => void archive()}
            >
              {t("portal.archive")}
            </button>
          )}
        </div>
      )}
      <div id={healthId}>
        {showHealth && health !== null ? <HealthPanel health={health} /> : null}
      </div>
      {endpoint.state === "archived" ? null : (
        <form className="relay-dialog" onSubmit={recover} aria-labelledby={recoverId}>
          <p className="relay-label" id={recoverId}>
            {t("portal.recover")}
          </p>
          <p className="relay-muted">{t("portal.recoverHint")}</p>
          <div className="relay-row">
            <label className="relay-field">
              <span>{t("portal.since")}</span>
              <input
                className="relay-input"
                type="datetime-local"
                value={since}
                onChange={(event) => setSince(event.target.value)}
                required
              />
            </label>
            <label className="relay-field">
              <span>{t("portal.until")}</span>
              <input
                className="relay-input"
                type="datetime-local"
                value={until}
                onChange={(event) => setUntil(event.target.value)}
              />
            </label>
            <button type="submit" className="relay-button relay-button-small">
              {t("portal.recover")}
            </button>
          </div>
        </form>
      )}
    </li>
  );
}

function MessageRow({
  api,
  message,
  flash,
}: {
  readonly api: PortalApi;
  readonly message: PortalMessage;
  readonly flash: (flash: Flash) => void;
}): ReactNode {
  const { t, formatTime } = useRelay();
  const [attempts, setAttempts] = useState<PortalAttempt[] | null>(null);
  const [open, setOpen] = useState(false);
  const attemptsId = useId();
  const toggle = () => {
    const next = !open;
    setOpen(next);
    if (next && attempts === null)
      api
        .attempts(message.id)
        .then(setAttempts)
        .catch(() => flash({ error: true, text: t("common.error") }));
  };
  const resend = () =>
    api
      .resend(message.id)
      .then(() => flash({ error: false, text: t("portal.resent") }))
      .catch((error: unknown) =>
        flash({
          error: true,
          text:
            error instanceof RelayApiError && error.code === "webhook_message_in_flight"
              ? t("portal.inFlight")
              : t("common.error"),
        }),
      );
  return (
    <li className="relay-card" data-testid="relay-message">
      <p className="relay-status">
        <StatusGlyph glyph={stateGlyph(message.state)} />
        {t("portal.message", {
          event: message.event_type,
          state: t(`portal.msg.${message.state}` as MessageKey),
          time: formatTime(message.created_at),
        })}
      </p>
      {message.next_attempt_at === null ? null : (
        <p>{t("portal.nextAttempt", { time: formatTime(message.next_attempt_at) })}</p>
      )}
      <div className="relay-row">
        <button
          type="button"
          className="relay-button relay-button-small"
          aria-expanded={open}
          aria-controls={attemptsId}
          onClick={toggle}
        >
          {t("portal.attempts")}
        </button>
        {message.state === "delivered" ? null : (
          <button
            type="button"
            className="relay-button relay-button-small"
            onClick={() => void resend()}
          >
            {t("portal.resend")}
          </button>
        )}
      </div>
      <div id={attemptsId}>
        {open && attempts !== null ? (
          <ol>
            {attempts.map((attempt) => (
              <li key={attempt.id}>
                {t("portal.attempt", {
                  n: attempt.attempt_no,
                  result: t(`portal.result.${attempt.result ?? "running"}` as MessageKey),
                })}
                {attempt.response_status === null ? null : (
                  <span className="relay-muted">
                    {" "}
                    {t("portal.attemptDetail", {
                      status: attempt.response_status,
                      ms: attempt.duration_ms ?? 0,
                    })}
                  </span>
                )}
                {attempt.failure_code === null ? null : (
                  <span className="relay-code"> {attempt.failure_code}</span>
                )}
              </li>
            ))}
          </ol>
        ) : null}
      </div>
    </li>
  );
}

function DeliveryLog({
  api,
  endpoints,
  eventTypes,
  flash,
}: {
  readonly api: PortalApi;
  readonly endpoints: readonly PortalEndpoint[];
  readonly eventTypes: readonly PortalEventType[];
  readonly flash: (flash: Flash) => void;
}): ReactNode {
  const { t } = useRelay();
  const [filter, setFilter] = useState<MessageFilter>({});
  const [messages, setMessages] = useState<PortalMessage[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const headingId = useId();
  const load = useCallback(
    (from: string | null) => {
      setLoading(true);
      api
        .messages(filter, from)
        .then((result) => {
          setMessages((current) =>
            from === null ? [...result.data] : [...current, ...result.data],
          );
          setCursor(result.has_more ? result.next_cursor : null);
        })
        .catch(() => flash({ error: true, text: t("common.error") }))
        .finally(() => setLoading(false));
    },
    [api, filter, flash, t],
  );
  useEffect(() => {
    load(null);
  }, [load]);
  const select = (key: keyof MessageFilter, value: string) => {
    const next: Record<string, string> = { ...filter };
    if (value === "") delete next[key];
    else next[key] = value;
    setFilter(next);
  };
  return (
    <section aria-labelledby={headingId} data-testid="relay-delivery-log">
      <h3 className="relay-subheading" id={headingId}>
        {t("portal.log")}
      </h3>
      <div className="relay-row">
        <label className="relay-field">
          <span>{t("portal.filterEndpoint")}</span>
          <select
            className="relay-select"
            value={filter.endpoint_id ?? ""}
            onChange={(event) => select("endpoint_id", event.target.value)}
          >
            <option value="">{t("common.any")}</option>
            {endpoints.map((endpoint) => (
              <option key={endpoint.id} value={endpoint.id}>
                {endpoint.destination.url ?? endpoint.id}
              </option>
            ))}
          </select>
        </label>
        <label className="relay-field">
          <span>{t("portal.filterState")}</span>
          <select
            className="relay-select"
            value={filter.state ?? ""}
            onChange={(event) => select("state", event.target.value)}
          >
            <option value="">{t("common.any")}</option>
            {messageStates.map((state) => (
              <option key={state} value={state}>
                {t(`portal.msg.${state}` as MessageKey)}
              </option>
            ))}
          </select>
        </label>
        <label className="relay-field">
          <span>{t("portal.filterEvent")}</span>
          <select
            className="relay-select"
            value={filter.event_type ?? ""}
            onChange={(event) => select("event_type", event.target.value)}
          >
            <option value="">{t("common.any")}</option>
            {eventTypes.map((type) => (
              <option key={type.id} value={type.name}>
                {type.name}
              </option>
            ))}
          </select>
        </label>
      </div>
      {loading && messages.length === 0 ? (
        <p className="relay-muted" aria-busy="true">
          {t("common.loading")}
        </p>
      ) : messages.length === 0 ? (
        <p className="relay-muted">{t("portal.logEmpty")}</p>
      ) : (
        <ul className="relay-list">
          {messages.map((message) => (
            <MessageRow key={message.id} api={api} message={message} flash={flash} />
          ))}
        </ul>
      )}
      {cursor === null ? null : (
        <button type="button" className="relay-button" onClick={() => load(cursor)}>
          {t("common.loadMore")}
        </button>
      )}
    </section>
  );
}

/** The webhook portal without its themed root; {@link WebhookPortal} wraps it. */
export function WebhookPortalPanel({ headingLevel = 2 }: WebhookPortalProps): ReactNode {
  const { runtime, t, brand } = useRelay();
  const client = runtime.portal;
  const api = useMemo(() => (client === null ? null : new PortalApi(client)), [client]);
  const [endpoints, setEndpoints] = useState<PortalEndpoint[] | null>(null);
  const [eventTypes, setEventTypes] = useState<PortalEventType[]>([]);
  const [editing, setEditing] = useState<PortalEndpoint | "new" | null>(null);
  const [message, setMessage] = useState<Flash>(null);
  const [failed, setFailed] = useState(false);
  const headingId = useId();
  const flash = useCallback((next: Flash) => setMessage(next), []);

  const load = useCallback(() => {
    if (api === null) return;
    setFailed(false);
    Promise.all([api.endpoints(), api.eventTypes()])
      .then(([list, types]) => {
        setEndpoints(list);
        setEventTypes(types);
      })
      .catch(() => setFailed(true));
  }, [api]);
  useEffect(() => {
    load();
  }, [load]);

  const replace = (endpoint: PortalEndpoint) =>
    setEndpoints((current) => {
      const list = current ?? [];
      return list.some((entry) => entry.id === endpoint.id)
        ? list.map((entry) => (entry.id === endpoint.id ? endpoint : entry))
        : [endpoint, ...list];
    });

  const Heading = headingLevel === 2 ? "h2" : "h3";
  if (api === null) return null;
  return (
    <section className="relay-portal" aria-labelledby={headingId}>
      <div className="relay-brand">
        {brand.logoUrl === undefined ? null : <img src={brand.logoUrl} alt={brand.name ?? ""} />}
        <Heading className="relay-heading" id={headingId}>
          {t("portal.title")}
        </Heading>
      </div>
      <div role="status" aria-live="polite" data-testid="relay-portal-status">
        {message === null ? null : (
          <p className={message.error ? "relay-error" : "relay-success"}>{message.text}</p>
        )}
      </div>
      {failed ? (
        <div className="relay-notice" role="alert">
          <span className="relay-error">{t("common.error")}</span>
          <button type="button" className="relay-button relay-button-small" onClick={load}>
            {t("common.retry")}
          </button>
        </div>
      ) : null}
      <h3 className="relay-subheading">{t("portal.endpoints")}</h3>
      {editing === null ? (
        <button
          type="button"
          className="relay-button relay-button-primary"
          onClick={() => setEditing("new")}
        >
          {t("portal.addEndpoint")}
        </button>
      ) : (
        <EndpointForm
          key={editing === "new" ? "new" : editing.id}
          api={api}
          eventTypes={eventTypes}
          endpoint={editing === "new" ? null : editing}
          onCancel={() => setEditing(null)}
          onDone={(endpoint, text) => {
            replace(endpoint);
            setEditing(null);
            flash({ error: false, text });
          }}
        />
      )}
      {endpoints === null ? (
        failed ? null : (
          <p className="relay-muted" aria-busy="true">
            {t("common.loading")}
          </p>
        )
      ) : endpoints.length === 0 ? (
        <p className="relay-muted">{t("portal.endpointsEmpty")}</p>
      ) : (
        <ul className="relay-list">
          {endpoints.map((endpoint) => (
            <EndpointCard
              key={endpoint.id}
              api={api}
              endpoint={endpoint}
              onChanged={replace}
              onEdit={setEditing}
              flash={flash}
            />
          ))}
        </ul>
      )}
      <DeliveryLog api={api} endpoints={endpoints ?? []} eventTypes={eventTypes} flash={flash} />
    </section>
  );
}

/**
 * The embeddable webhook portal (X-23, WH-39, WH-46, WH-47) on the portal API family with the tenant-minted, consumer-bound portal token: endpoints added, edited, disabled and archived with the address check's answer shown at the field, event types chosen from the tenant's catalog, endpoint health with the disable reason, signing key rotation, test events, the delivery log with each attempt, resending one delivery and resending the failed deliveries of a time range. New endpoints use the Ed25519 scheme, whose private key never leaves Relay.
 */
export function WebhookPortal(props: WebhookPortalProps): ReactNode {
  return (
    <RelayRoot>
      <WebhookPortalPanel {...props} />
    </RelayRoot>
  );
}
