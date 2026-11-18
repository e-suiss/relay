import { useId, useState, type ReactNode } from "react";
import { useGet } from "../../api/hooks";
import type { ChannelRender } from "../../api/pending";
import type { ChannelCostQuote } from "../../api/types";
import { useI18n } from "../../i18n/i18n";
import { sandboxSource } from "../../lib/sandbox";
import { measureSms, transliterate } from "../../lib/sms";
import { formatMicros } from "../../pages/reports/Reports";
import { ChannelLabel } from "../status";

type Fields = Record<string, unknown>;

function text(fields: Fields, name: string): string {
  const value = fields[name];
  return typeof value === "string" ? value : "";
}

function Frame({
  label,
  className,
  children,
}: {
  label: string;
  className: string;
  children: ReactNode;
}) {
  return (
    <figure className={`device ${className}`}>
      <figcaption className="small muted">{label}</figcaption>
      <div className="device-screen">{children}</div>
    </figure>
  );
}

// TP-38
function PushViews({ fields }: { fields: Fields }) {
  const { t } = useI18n();
  const title = text(fields, "title");
  const subtitle = text(fields, "subtitle");
  const body = text(fields, "body");
  const lock = text(fields, "lock_screen_body");
  return (
    <div className="device-row">
      <Frame label={t("pv.iosLock")} className="ios lock">
        <div className="note-card">
          <strong>{title}</strong>
          <p>{lock === "" ? body : lock}</p>
        </div>
      </Frame>
      <Frame label={t("pv.iosCentre")} className="ios centre">
        <div className="note-card">
          <strong>{title}</strong>
          {subtitle !== "" && <span className="small">{subtitle}</span>}
          <p>{body}</p>
        </div>
      </Frame>
      <Frame label={t("pv.androidCollapsed")} className="android">
        <div className="note-card collapsed">
          <strong>{title}</strong>
          <p className="one-line">{body}</p>
        </div>
      </Frame>
      <Frame label={t("pv.androidExpanded")} className="android">
        <div className="note-card">
          <strong>{title}</strong>
          {subtitle !== "" && <span className="small">{subtitle}</span>}
          <p>{body}</p>
        </div>
      </Frame>
    </div>
  );
}

function SmsCost({ segments }: { segments: number }) {
  const { t } = useI18n();
  const id = useId();
  const [country, setCountry] = useState("TR");
  const [asked, setAsked] = useState<string | null>(null);
  const quote = useGet<ChannelCostQuote>(
    asked === null ? null : "/v1/channel_costs",
    { channel: "sms", country: asked, quantity: Math.max(segments, 1) },
  );
  const row =
    quote.state.kind === "ready"
      ? quote.state.data.data.find((item) => item.priced)
      : undefined;
  return (
    <div className="row filters">
      <div className="field">
        <label htmlFor={id}>{t("reports.country")}</label>
        <input
          id={id}
          value={country}
          maxLength={2}
          size={3}
          onChange={(event) => {
            setCountry(event.target.value.toUpperCase());
          }}
        />
      </div>
      <button
        type="button"
        onClick={() => {
          setAsked(country);
        }}
      >
        {t("pv.estimateCost")}
      </button>
      {quote.state.kind === "ready" && (
        <span role="status" data-sms-cost>
          {row === undefined
            ? t("channels.notPriced")
            : t("pv.cost", {
                cost: formatMicros(
                  row.total_micros === null ? null : String(row.total_micros),
                  row.currency,
                ),
                provider: row.provider,
              })}
        </span>
      )}
      {quote.state.kind === "error" && (
        <span role="status">{t("channels.notPriced")}</span>
      )}
    </div>
  );
}

function Bubble({ body, segments }: { body: string; segments: string[] }) {
  const { t } = useI18n();
  const parts = segments.length === 0 ? [body] : segments;
  return (
    <div className="bubble sms-bubble">
      {parts.map((part, index) => (
        <span key={index} className="segment">
          {parts.length > 1 && (
            <span className="segment-mark small">
              {t("pv.segmentN", { n: index + 1 })}
            </span>
          )}
          {part}
        </span>
      ))}
    </div>
  );
}

// TP-38
// TP-18
function SmsView({
  render,
  fields,
}: {
  render: ChannelRender;
  fields: Fields;
}) {
  const { t } = useI18n();
  const body = text(fields, "body") || text(fields, "text");
  const local = measureSms(body);
  const after = transliterate(body);
  const afterMeasure = measureSms(after);
  const encoding = render.sms?.encoding ?? local.encoding;
  const count = render.sms?.segments ?? local.segments.length;
  const unverified = render.sms?.encoding_unverified_provider;
  return (
    <div className="stack">
      <Frame label={t("pv.smsBubble")} className="phone">
        <Bubble body={body} segments={local.segments} />
      </Frame>
      <dl className="key-values">
        <div>
          <dt>{t("pv.encoding")}</dt>
          <dd data-sms-encoding>{encoding}</dd>
        </div>
        <div>
          <dt>{t("pv.segments")}</dt>
          <dd data-sms-segments>{count}</dd>
        </div>
        <div>
          <dt>{t("pv.characters")}</dt>
          <dd>{render.sms?.characters ?? local.characters}</dd>
        </div>
        {unverified !== undefined && unverified !== encoding && (
          <div>
            <dt>{t("pv.unverifiedProvider")}</dt>
            <dd>{unverified}</dd>
          </div>
        )}
      </dl>
      <SmsCost segments={count} />
      <details>
        <summary>{t("pv.transliteration")}</summary>
        <div className="device-row">
          <Frame label={t("pv.before")} className="phone">
            <Bubble body={body} segments={local.segments} />
            <p className="small muted">
              {t("pv.measure", {
                encoding: local.encoding,
                segments: local.segments.length,
              })}
            </p>
          </Frame>
          <Frame label={t("pv.after")} className="phone">
            <Bubble body={after} segments={afterMeasure.segments} />
            <p className="small muted" data-transliterated>
              {t("pv.measure", {
                encoding: afterMeasure.encoding,
                segments: afterMeasure.segments.length,
              })}
            </p>
          </Frame>
        </div>
      </details>
    </div>
  );
}

function WhatsappView({ fields }: { fields: Fields }) {
  const { t } = useI18n();
  const body = text(fields, "body") || text(fields, "text");
  const parameters = Array.isArray(fields.parameters)
    ? (fields.parameters as unknown[])
    : [];
  return (
    <Frame label={t("pv.whatsappBubble")} className="phone">
      <div className="bubble wa-bubble">
        {text(fields, "template_name") !== "" && (
          <span className="small mono">{text(fields, "template_name")}</span>
        )}
        {body !== "" && <p>{body}</p>}
        {parameters.length > 0 && (
          <ul className="plain small">
            {parameters.map((item, index) => (
              <li key={index}>
                {typeof item === "object" && item !== null
                  ? `${text(item as Fields, "name")}: ${text(item as Fields, "value")}`
                  : JSON.stringify(item)}
              </li>
            ))}
          </ul>
        )}
      </div>
    </Frame>
  );
}

function InboxView({ fields }: { fields: Fields }) {
  const { t } = useI18n();
  const actions = Array.isArray(fields.actions)
    ? (fields.actions as unknown[])
    : [];
  return (
    <Frame label={t("pv.inboxRow")} className="inbox">
      <div className="inbox-row">
        <span className="avatar" aria-hidden="true">
          {text(fields, "title").slice(0, 1).toUpperCase()}
        </span>
        <div className="stack tight">
          <strong>{text(fields, "title")}</strong>
          <span>{text(fields, "body")}</span>
          {actions.length > 0 && (
            <span className="row">
              {actions.map((action, index) => (
                <span key={index} className="chip">
                  {typeof action === "object" && action !== null
                    ? text(action as Fields, "label")
                    : ""}
                </span>
              ))}
            </span>
          )}
        </div>
      </div>
    </Frame>
  );
}

export function SandboxFrame({
  url,
  title,
  dark,
  narrow,
}: {
  url: string | null | undefined;
  title: string;
  dark: boolean;
  narrow: boolean;
}) {
  const { t } = useI18n();
  const source = sandboxSource(url, window.location.origin);
  if (source === null)
    return (
      <p className="notice" data-sandbox-missing>
        {t("pv.sandboxMissing")}
      </p>
    );
  return (
    <iframe
      className={`sandbox-frame${dark ? " dark" : ""}${narrow ? " narrow" : ""}`}
      title={title}
      src={source}
      sandbox=""
      referrerPolicy="no-referrer"
      loading="lazy"
    />
  );
}

function kilobytes(bytes: number): string {
  return (bytes / 1024).toFixed(1);
}

// TP-38
// TP-22
// TP-39
function EmailView({
  render,
  fields,
  dark,
  narrow,
}: {
  render: ChannelRender;
  fields: Fields;
  dark: boolean;
  narrow: boolean;
}) {
  const { t } = useI18n();
  const [tab, setTab] = useState<"html" | "text">("html");
  const bytes = render.measures?.bytes;
  const tone =
    bytes === undefined
      ? "neutral"
      : bytes > 90 * 1024
        ? "bad"
        : bytes > 70 * 1024
          ? "warn"
          : "ok";
  return (
    <div className="stack">
      <dl className="key-values">
        <div>
          <dt>{t("tpl.field.subject")}</dt>
          <dd data-email-subject>{text(fields, "subject")}</dd>
        </div>
        <div>
          <dt>{t("tpl.field.preheader")}</dt>
          <dd>{text(fields, "preheader") || "—"}</dd>
        </div>
        <div>
          <dt>{t("pv.htmlSize")}</dt>
          <dd>
            {bytes === undefined ? (
              "—"
            ) : (
              <span className={`badge tone-${tone}`} data-email-size>
                <span className="badge-label">
                  {t("pv.kb", { kb: kilobytes(bytes) })}
                </span>
              </span>
            )}
          </dd>
        </div>
      </dl>
      <div className="row" role="group" aria-label={t("pv.emailView")}>
        <button
          type="button"
          aria-pressed={tab === "html"}
          onClick={() => {
            setTab("html");
          }}
        >
          {t("pv.html")}
        </button>
        <button
          type="button"
          aria-pressed={tab === "text"}
          onClick={() => {
            setTab("text");
          }}
        >
          {t("pv.plainText")}
        </button>
      </div>
      {tab === "html" ? (
        <SandboxFrame
          url={render.sandbox_url}
          title={t("pv.emailFrame", { subject: text(fields, "subject") })}
          dark={dark}
          narrow={narrow}
        />
      ) : (
        <pre className={`plain-text${narrow ? " narrow" : ""}`} tabIndex={0}>
          {text(fields, "text")}
        </pre>
      )}
    </div>
  );
}

function OtherView({ fields }: { fields: Fields }) {
  const body = text(fields, "body");
  return (
    <pre className="plain-text" tabIndex={0}>
      {body === "" ? JSON.stringify(fields, null, 2) : body}
    </pre>
  );
}

function body(
  render: ChannelRender,
  fields: Fields,
  dark: boolean,
  narrow: boolean,
): ReactNode {
  switch (render.channel) {
    case "push":
    case "web_push":
      return <PushViews fields={fields} />;
    case "sms":
      return <SmsView render={render} fields={fields} />;
    case "whatsapp":
      return <WhatsappView fields={fields} />;
    case "in_app":
      return <InboxView fields={fields} />;
    case "email":
      return (
        <EmailView
          render={render}
          fields={fields}
          dark={dark}
          narrow={narrow}
        />
      );
    default:
      return <OtherView fields={fields} />;
  }
}

// TP-38
/** A channel-faithful view of one render: device frames for push, an SMS bubble with segments, encoding, cost and transliteration, a WhatsApp bubble, an inbox row, or the e-mail with its size, plain text and sandboxed HTML; with dark mode and a narrow width. */
export function ChannelPreview({
  render,
  heading,
}: {
  render: ChannelRender;
  heading?: ReactNode;
}) {
  const { t } = useI18n();
  const [dark, setDark] = useState(false);
  const [narrow, setNarrow] = useState(false);
  const darkId = useId();
  const narrowId = useId();
  const fields: Fields = render.content ?? {};
  return (
    <article
      className={`preview panel stack${dark ? " preview-dark" : ""}`}
      data-preview={render.channel}
    >
      <div className="row section-head">
        <h3 className="preview-title">
          <ChannelLabel channel={render.channel} /> ·{" "}
          <span>{render.locale}</span>
          {heading}
        </h3>
        <div className="row">
          <label className="inline" htmlFor={darkId}>
            <input
              id={darkId}
              type="checkbox"
              checked={dark}
              onChange={(event) => {
                setDark(event.target.checked);
              }}
            />
            {t("pv.dark")}
          </label>
          <label className="inline" htmlFor={narrowId}>
            <input
              id={narrowId}
              type="checkbox"
              checked={narrow}
              onChange={(event) => {
                setNarrow(event.target.checked);
              }}
            />
            {t("pv.narrow")}
          </label>
        </div>
      </div>
      {render.locale_fallback === true && (
        <p className="notice small">{t("pv.localeFallback")}</p>
      )}
      {render.failure_reason !== null &&
        render.failure_reason !== undefined && (
          <p role="alert" className="notice">
            {t("pv.failed", { reason: render.failure_reason })}
          </p>
        )}
      <div className={`preview-stage${narrow ? " narrow" : ""}`}>
        {body(render, fields, dark, narrow)}
      </div>
      {render.warnings.length > 0 && (
        <ul className="plain small">
          {render.warnings.map((warning, index) => (
            <li key={index}>
              <code className="mono">{warning.code}</code> {warning.message}
            </li>
          ))}
        </ul>
      )}
    </article>
  );
}
