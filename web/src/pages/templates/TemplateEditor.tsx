import { useEffect, useId, useState, type SyntheticEvent } from "react";
import { ApiError, etag, idempotencyKey } from "../../api/client";
import { useGet, useMutation } from "../../api/hooks";
import type {
  ChannelRender,
  GateFinding,
  TemplatePublicationCheck,
} from "../../api/pending";
import type { Page, ServerSchemas } from "../../api/types";
import { Link } from "../../app/router";
import { Loadable, Mono, Section } from "../../components/data";
import { ChannelPreview } from "../../components/preview/ChannelPreview";
import { ChannelLabel } from "../../components/status";
import { useI18n } from "../../i18n/i18n";
import {
  freshName,
  pluralCategories,
  pluralSnippet,
  samplePlural,
  variablePattern,
  type PluralCategory,
} from "../../lib/plural";
import { measureSms } from "../../lib/sms";
import { htmlToText, smsDraftFromEmail } from "../../lib/text";
import { problemText, useStepUp } from "../../session/stepUp";
import {
  cellChannels,
  cellFields,
  cellText,
  emptyCell,
  getCell,
  localePattern,
  locales,
  setCell,
  type Cell,
  type CellChannel,
} from "./cells";

type Template = ServerSchemas["Template"];
type Definition = ServerSchemas["TemplateDefinition"];
type Translations = ServerSchemas["TemplateTranslations"];
type TemplatePreview = ServerSchemas["TemplatePreview"];
type TemplateVersion = ServerSchemas["TemplateVersion"];
type Workflow = ServerSchemas["Workflow"];
type CellStatus = Translations["cells"][number]["status"] | "local";

const enc = encodeURIComponent;

const statusGlyph: Record<CellStatus, string> = {
  present: "●",
  approved: "✓",
  machine_translated: "◐",
  missing: "○",
  local: "✎",
};

// TP-10
// TP-30
/** The channel × locale matrix: each cell is a variant written for its channel, with its translation state. */
function Matrix({
  definition,
  extraLocales,
  translations,
  selected,
  onSelect,
  onAddLocale,
  readOnly,
}: {
  definition: Definition;
  extraLocales: readonly string[];
  translations: Translations | null;
  selected: { channel: CellChannel; locale: string } | null;
  onSelect: (channel: CellChannel, locale: string) => void;
  onAddLocale: (locale: string) => void;
  readOnly: boolean;
}) {
  const { t } = useI18n();
  const id = useId();
  const [locale, setLocale] = useState("");
  const columns = [
    ...new Set([
      ...locales(definition.default_locale, definition.cells),
      ...(translations?.locales ?? []),
      ...extraLocales,
    ]),
  ];
  const status = (channel: CellChannel, at: string): CellStatus => {
    const present = getCell(definition.cells, channel, at) !== null;
    const remote = translations?.cells.find(
      (cell) => cell.channel === channel && cell.locale === at,
    );
    if (remote === undefined) return present ? "local" : "missing";
    if (present && remote.status === "missing") return "local";
    return remote.status;
  };
  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (localePattern.test(locale)) {
      onAddLocale(locale);
      setLocale("");
    }
  };
  return (
    <Section title={t("tpl.matrix")}>
      <p className="small muted">{t("tpl.matrixIntro")}</p>
      <div className="table-wrap">
        <table className="matrix">
          <caption className="visually-hidden">{t("tpl.matrix")}</caption>
          <thead>
            <tr>
              <th scope="col">{t("why.channel")}</th>
              {columns.map((column) => (
                <th key={column} scope="col">
                  {column}
                  {column === definition.default_locale && (
                    <span className="small muted"> {t("tpl.default")}</span>
                  )}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {cellChannels.map((channel) => (
              <tr key={channel}>
                <th scope="row">
                  <ChannelLabel channel={channel} />
                </th>
                {columns.map((column) => {
                  const state = status(channel, column);
                  const current =
                    selected?.channel === channel && selected.locale === column;
                  return (
                    <td key={column}>
                      <button
                        type="button"
                        className={`cell cell-${state}`}
                        aria-pressed={current}
                        data-cell={`${channel}:${column}`}
                        onClick={() => {
                          onSelect(channel, column);
                        }}
                      >
                        <span aria-hidden="true">{statusGlyph[state]}</span>{" "}
                        {t(`tpl.status.${state}`)}
                      </button>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {!readOnly && (
        <form className="row filters" onSubmit={submit}>
          <div className="field">
            <label htmlFor={id}>{t("tpl.addLocale")}</label>
            <input
              id={id}
              value={locale}
              placeholder="en-GB"
              aria-invalid={locale !== "" && !localePattern.test(locale)}
              onChange={(event) => {
                setLocale(event.target.value.trim());
              }}
            />
          </div>
          <button type="submit" disabled={!localePattern.test(locale)}>
            {t("tpl.addLocaleButton")}
          </button>
        </form>
      )}
    </Section>
  );
}

// TP-27
/** Writes a plural field from one input per CLDR category of the cell's language; the ICU message is generated behind and inserted as Liquid. */
function PluralHelper({
  locale,
  fields,
  onInsert,
}: {
  locale: string;
  fields: readonly string[];
  onInsert: (field: string, snippet: (text: string) => string) => void;
}) {
  const { t } = useI18n();
  const ids = {
    field: useId(),
    variable: useId(),
    zero: useId(),
    zeroText: useId(),
    sample: useId(),
  };
  const categories = pluralCategories(locale);
  const [target, setTarget] = useState(fields[0] ?? "");
  const [variable, setVariable] = useState("data.count");
  const [useZero, setUseZero] = useState(false);
  const [zero, setZero] = useState("");
  const [forms, setForms] = useState<Partial<Record<PluralCategory, string>>>(
    {},
  );
  const [sample, setSample] = useState(3);
  const value = { variable, zero: useZero ? zero : null, forms };
  const ready =
    variablePattern.test(variable) &&
    categories.every((category) => (forms[category] ?? "").trim() !== "");
  return (
    <details className="panel" data-plural-helper>
      <summary>{t("tpl.plural")}</summary>
      <div className="stack">
        <p className="small muted">
          {t("tpl.pluralIntro", { locale, categories: categories.join(", ") })}
        </p>
        <div className="row filters">
          <div className="field">
            <label htmlFor={ids.field}>{t("tpl.pluralField")}</label>
            <select
              id={ids.field}
              value={target}
              onChange={(event) => {
                setTarget(event.target.value);
              }}
            >
              {fields.map((name) => (
                <option key={name} value={name}>
                  {t(`tpl.field.${name}` as "tpl.field.body")}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor={ids.variable}>{t("tpl.pluralVariable")}</label>
            <input
              id={ids.variable}
              value={variable}
              aria-invalid={!variablePattern.test(variable)}
              onChange={(event) => {
                setVariable(event.target.value.trim());
              }}
            />
          </div>
        </div>
        <label className="inline" htmlFor={ids.zero}>
          <input
            id={ids.zero}
            type="checkbox"
            checked={useZero}
            onChange={(event) => {
              setUseZero(event.target.checked);
            }}
          />
          {t("tpl.pluralZero")}
        </label>
        {useZero && (
          <div className="field">
            <label htmlFor={ids.zeroText}>{t("tpl.pluralZeroText")}</label>
            <input
              id={ids.zeroText}
              value={zero}
              onChange={(event) => {
                setZero(event.target.value);
              }}
            />
          </div>
        )}
        {categories.map((category) => (
          <PluralInput
            key={category}
            category={category}
            value={forms[category] ?? ""}
            onChange={(text) => {
              setForms({ ...forms, [category]: text });
            }}
          />
        ))}
        <div className="row filters">
          <div className="field">
            <label htmlFor={ids.sample}>{t("tpl.pluralSample")}</label>
            <input
              id={ids.sample}
              type="number"
              min={0}
              value={sample}
              onChange={(event) => {
                setSample(Math.max(0, Number(event.target.value)));
              }}
            />
          </div>
          <output htmlFor={ids.sample} data-plural-sample>
            {samplePlural(value, sample, locale)}
          </output>
        </div>
        <span>
          <button
            type="button"
            disabled={!ready || target === ""}
            onClick={() => {
              onInsert(
                target,
                (text) =>
                  `${text}${pluralSnippet(freshName(text), value, locale)}`,
              );
            }}
          >
            {t("tpl.pluralInsert")}
          </button>
        </span>
      </div>
    </details>
  );
}

function PluralInput({
  category,
  value,
  onChange,
}: {
  category: PluralCategory;
  value: string;
  onChange: (value: string) => void;
}) {
  const { t } = useI18n();
  const id = useId();
  return (
    <div className="field">
      <label htmlFor={id}>{t(`tpl.category.${category}`)}</label>
      <input
        id={id}
        value={value}
        data-plural-category={category}
        placeholder="# …"
        onChange={(event) => {
          onChange(event.target.value);
        }}
      />
    </div>
  );
}

function TextField({
  name,
  multiline,
  value,
  disabled,
  onChange,
  after,
}: {
  name: string;
  multiline: boolean;
  value: string;
  disabled: boolean;
  onChange: (value: string) => void;
  after?: string;
}) {
  const { t } = useI18n();
  const id = useId();
  const label = t(`tpl.field.${name}` as "tpl.field.body");
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      {multiline ? (
        <textarea
          id={id}
          rows={name === "html" ? 10 : 4}
          className={name === "html" ? "mono" : undefined}
          value={value}
          disabled={disabled}
          data-field={name}
          onChange={(event) => {
            onChange(event.target.value);
          }}
        />
      ) : (
        <input
          id={id}
          value={value}
          disabled={disabled}
          data-field={name}
          onChange={(event) => {
            onChange(event.target.value);
          }}
        />
      )}
      {after !== undefined && <span className="small muted">{after}</span>}
    </div>
  );
}

// TP-10
// TP-22
// TP-27
function CellEditor({
  channel,
  locale,
  definition,
  readOnly,
  onChange,
}: {
  channel: CellChannel;
  locale: string;
  definition: Definition;
  readOnly: boolean;
  onChange: (cell: Cell | null) => void;
}) {
  const { t } = useI18n();
  const kindId = useId();
  const [note, setNote] = useState<string | null>(null);
  const cell = getCell(definition.cells, channel, locale);
  const email = getCell(definition.cells, "email", locale);
  if (cell === null)
    return (
      <Section
        title={t("tpl.cellTitle", { channel: t(`channel.${channel}`), locale })}
      >
        <p className="muted">{t("tpl.noVariant")}</p>
        {!readOnly && (
          <span>
            <button
              type="button"
              className="primary"
              onClick={() => {
                onChange(emptyCell(channel));
              }}
            >
              {t("tpl.addVariant")}
            </button>
          </span>
        )}
      </Section>
    );
  const fields = cellFields[channel];
  const update = (name: string, value: string) => {
    onChange({ ...cell, [name]: value });
  };
  const sms = channel === "sms" ? measureSms(cellText(cell, "body")) : null;
  return (
    <Section
      title={t("tpl.cellTitle", { channel: t(`channel.${channel}`), locale })}
      actions={
        readOnly ? undefined : (
          <button
            type="button"
            onClick={() => {
              onChange(null);
            }}
          >
            {t("tpl.removeVariant")}
          </button>
        )
      }
    >
      <div className="stack" data-cell-editor={`${channel}:${locale}`}>
        {channel === "email" && (
          <div className="field">
            <label htmlFor={kindId}>{t("tpl.htmlKind")}</label>
            <select
              id={kindId}
              value={cellText(cell, "html_kind") || "mjml"}
              disabled={readOnly}
              onChange={(event) => {
                update("html_kind", event.target.value);
              }}
            >
              <option value="mjml">MJML</option>
              <option value="raw_html">{t("tpl.rawHtml")}</option>
            </select>
          </div>
        )}
        {fields.map((field) => (
          <TextField
            key={field.name}
            name={field.name}
            multiline={field.multiline}
            value={cellText(cell, field.name)}
            disabled={readOnly}
            onChange={(value) => {
              update(field.name, value);
            }}
            {...(sms !== null && field.name === "body"
              ? {
                  after: t("pv.measure", {
                    encoding: sms.encoding,
                    segments: sms.segments.length,
                  }),
                }
              : {})}
          />
        ))}
        {!readOnly && (
          <div className="row">
            {channel === "email" && (
              <button
                type="button"
                data-helper="text-from-html"
                disabled={cellText(cell, "html").trim() === ""}
                onClick={() => {
                  update("text", htmlToText(cellText(cell, "html")));
                  setNote(t("tpl.textDrafted"));
                }}
              >
                {t("tpl.textFromHtml")}
              </button>
            )}
            {channel === "sms" && (
              <button
                type="button"
                data-helper="sms-from-email"
                disabled={email === null}
                onClick={() => {
                  if (email === null) return;
                  update(
                    "body",
                    smsDraftFromEmail({
                      subject: cellText(email, "subject"),
                      text: cellText(email, "text"),
                      html: cellText(email, "html"),
                    }),
                  );
                  setNote(t("tpl.smsDrafted"));
                }}
              >
                {t("tpl.smsFromEmail")}
              </button>
            )}
          </div>
        )}
        {note !== null && (
          <p role="status" className="notice small">
            {note}
          </p>
        )}
        {!readOnly && (
          <PluralHelper
            key={`${channel}:${locale}`}
            locale={locale}
            fields={fields
              .filter((field) => field.name !== "html")
              .map((field) => field.name)}
            onInsert={(name, build) => {
              update(name, build(cellText(cell, name)));
            }}
          />
        )}
      </div>
    </Section>
  );
}

function Findings({ findings }: { findings: readonly GateFinding[] }) {
  const { t } = useI18n();
  if (findings.length === 0) return null;
  return (
    <ul className="plain stack tight">
      {findings.map((finding, index) => (
        <li key={`${finding.check}-${index}`} data-finding={finding.level}>
          <span
            className={`badge tone-${finding.level === "hard" ? "bad" : "warn"}`}
          >
            <span className="badge-label">
              {t(`tpl.level.${finding.level}`)}
            </span>
          </span>{" "}
          <code className="mono">{finding.check}</code>
          {finding.channel !== undefined && (
            <>
              {" · "}
              <ChannelLabel channel={finding.channel} />
            </>
          )}
          {finding.locale !== undefined && ` · ${finding.locale}`} —{" "}
          {finding.message}
        </li>
      ))}
    </ul>
  );
}

function findingsOf(error: unknown): GateFinding[] {
  if (!(error instanceof ApiError)) return [];
  const problem = error.problem as { findings?: GateFinding[] } | null;
  return problem?.findings ?? [];
}

// TP-38
function TemplatePreviewPanel({ templateKey }: { templateKey: string }) {
  const { t } = useI18n();
  const mutate = useMutation();
  const ids = {
    workflow: useId(),
    version: useId(),
    sample: useId(),
    locale: useId(),
  };
  const workflows = useGet<Page<Workflow>>("/v1/workflows", { limit: 100 });
  const [form, setForm] = useState({
    workflow: "",
    version: "draft",
    sample: "boundary",
    locale: "",
  });
  const [result, setResult] = useState<TemplatePreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(null);
    mutate<TemplatePreview>(
      "POST",
      `/v1/templates/${enc(templateKey)}/preview`,
      {
        workflow: form.workflow,
        version: /^\d+$/.test(form.version)
          ? Number(form.version)
          : form.version,
        sample: form.sample,
        ...(form.locale === "" ? {} : { locale: form.locale }),
      },
      idempotencyKey(),
    ).then(setResult, (failure: unknown) => {
      setError(problemText(failure));
    });
  };
  const options =
    workflows.state.kind === "ready" ? workflows.state.data.data : [];
  return (
    <Section title={t("tpl.preview")}>
      <p className="small muted">{t("tpl.previewIntro")}</p>
      <form className="row filters" onSubmit={submit}>
        <div className="field">
          <label htmlFor={ids.workflow}>{t("activity.workflow")}</label>
          <select
            id={ids.workflow}
            value={form.workflow}
            required
            onChange={(event) => {
              setForm({ ...form, workflow: event.target.value });
            }}
          >
            <option value="">{t("tpl.chooseWorkflow")}</option>
            {options.map((item) => (
              <option key={item.key} value={item.key}>
                {item.key}
              </option>
            ))}
          </select>
        </div>
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
              setForm({ ...form, sample: event.target.value });
            }}
          >
            <option value="boundary">{t("wf.sample.boundary")}</option>
            <option value="schema_examples">
              {t("wf.sample.schema_examples")}
            </option>
            <option value="masked_recent">
              {t("wf.sample.masked_recent")}
            </option>
          </select>
        </div>
        <div className="field">
          <label htmlFor={ids.locale}>{t("why.locale")}</label>
          <input
            id={ids.locale}
            value={form.locale}
            size={8}
            onChange={(event) => {
              setForm({ ...form, locale: event.target.value });
            }}
          />
        </div>
        <button
          type="submit"
          className="primary"
          disabled={form.workflow === ""}
        >
          {t("wf.runPreview")}
        </button>
      </form>
      {error !== null && <p role="alert">{error}</p>}
      {result !== null && (
        <div className="stack" data-template-preview>
          {result.renders.map((render, index) => (
            <ChannelPreview
              key={`${render.channel}-${render.locale}-${index}`}
              render={render as ChannelRender}
            />
          ))}
        </div>
      )}
    </Section>
  );
}

function Editor({ initial }: { initial: Template }) {
  const { t } = useI18n();
  const mutate = useMutation();
  const stepUp = useStepUp();
  const [template, setTemplate] = useState(initial);
  const [definition, setDefinition] = useState<Definition | null>(
    initial.draft ?? null,
  );
  const [dirty, setDirty] = useState(false);
  const [selected, setSelected] = useState<{
    channel: CellChannel;
    locale: string;
  } | null>(null);
  const [extraLocales, setExtraLocales] = useState<string[]>([]);
  const [acceptWarnings, setAcceptWarnings] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [findings, setFindings] = useState<GateFinding[]>([]);
  const [saveKey, setSaveKey] = useState(idempotencyKey);
  const translations = useGet<Translations>(
    `/v1/templates/${enc(template.key)}/translations`,
    { source: "draft" },
  );
  const check = useGet<TemplatePublicationCheck>(
    `/v1/templates/${enc(template.key)}/publication_check`,
  );
  const reloadCheck = check.reload;
  const reloadTranslations = translations.reload;
  useEffect(() => {
    if (!dirty) {
      reloadCheck();
      reloadTranslations();
    }
  }, [template.version, dirty, reloadCheck, reloadTranslations]);
  const readOnly = template.protected;

  if (definition === null)
    return (
      <div className="stack">
        <p className="muted">{t("tpl.noDraft")}</p>
        {!readOnly && (
          <span>
            <button
              type="button"
              onClick={() => {
                setDefinition({
                  default_locale: "tr-TR",
                  transliterate: false,
                  allow_raw: false,
                  cells: {},
                });
                setDirty(true);
              }}
            >
              {t("tpl.startDraft")}
            </button>
          </span>
        )}
      </div>
    );

  const save = () => {
    setError(null);
    mutate<Template>(
      "PUT",
      `/v1/templates/${enc(template.key)}`,
      { definition },
      saveKey,
      etag(template.version),
    ).then(
      (saved) => {
        setSaveKey(idempotencyKey());
        setTemplate(saved);
        setDirty(false);
        setMessage(t("wf.saved"));
      },
      (failure: unknown) => {
        if (!stepUp(failure)) setError(problemText(failure));
      },
    );
  };

  const gate = check.state.kind === "ready" ? check.state.data : null;
  const gateMissing =
    check.state.kind === "error" &&
    check.state.error instanceof ApiError &&
    check.state.error.status === 404;
  const warnings = (gate?.findings ?? findings).some(
    (item) => item.level === "warning",
  );
  const canPublish =
    !dirty &&
    !readOnly &&
    (gate === null ? gateMissing : gate.publishable) &&
    (!warnings || acceptWarnings);

  const publish = () => {
    setError(null);
    mutate<TemplateVersion>(
      "POST",
      `/v1/templates/${enc(template.key)}/publish`,
      {
        accept_warnings: acceptWarnings,
        ...(gate === null ? {} : { checksum: gate.checksum }),
      },
      idempotencyKey(),
      etag(template.version),
    ).then(
      (version) => {
        setFindings([]);
        setTemplate({ ...template, live_version: version.version });
        setMessage(t("wf.published", { version: version.version }));
      },
      (failure: unknown) => {
        if (stepUp(failure)) return;
        setFindings(findingsOf(failure));
        setError(problemText(failure));
      },
    );
  };

  return (
    <div className="stack">
      <div className="row">
        <Mono>{template.key}</Mono>
        <span className="muted">{t(`tpl.type.${template.type}`)}</span>
        <span className="muted">
          {template.live_version === null || template.live_version === undefined
            ? t("wf.notPublished")
            : t("wf.liveVersion", { version: template.live_version })}
        </span>
      </div>
      {readOnly && (
        <p className="notice" role="note">
          {t("tpl.protectedNote")}
        </p>
      )}
      <div className="row toolbar">
        <button
          type="button"
          className="primary"
          disabled={!dirty || readOnly}
          onClick={save}
        >
          {t("wf.saveDraft")}
        </button>
        <button
          type="button"
          data-publish
          disabled={!canPublish}
          onClick={publish}
        >
          {t("wf.publish")}
        </button>
        {warnings && (
          <label className="inline">
            <input
              type="checkbox"
              checked={acceptWarnings}
              onChange={(event) => {
                setAcceptWarnings(event.target.checked);
              }}
            />
            {t("tpl.acceptWarnings")}
          </label>
        )}
        {message !== null && <span role="status">{message}</span>}
      </div>
      {error !== null && <p role="alert">{error}</p>}
      <Section title={t("gate.title")}>
        {dirty && <p className="notice small">{t("gate.unsaved")}</p>}
        {gateMissing && (
          <p className="small muted" data-gate-mode="fallback">
            {t("tpl.gateFallback")}
          </p>
        )}
        {gate !== null && (
          <p data-gate={gate.publishable ? "pass" : "fail"}>
            <span className={`badge tone-${gate.publishable ? "ok" : "bad"}`}>
              <span className="badge-label">
                {gate.publishable ? t("gate.passes") : t("gate.blocked")}
              </span>
            </span>
          </p>
        )}
        <Findings findings={gate?.findings ?? findings} />
      </Section>
      <Matrix
        definition={definition}
        extraLocales={extraLocales}
        translations={
          translations.state.kind === "ready" ? translations.state.data : null
        }
        selected={selected}
        readOnly={readOnly}
        onSelect={(channel, locale) => {
          setSelected({ channel, locale });
        }}
        onAddLocale={(locale) => {
          setExtraLocales([...extraLocales, locale]);
          setSelected({ channel: "email", locale });
        }}
      />
      {extraLocales.length > 0 && (
        <p className="small muted">
          {t("tpl.newLocales", { locales: extraLocales.join(", ") })}
        </p>
      )}
      {selected !== null && (
        <CellEditor
          key={`${selected.channel}:${selected.locale}`}
          channel={selected.channel}
          locale={selected.locale}
          definition={definition}
          readOnly={readOnly}
          onChange={(cell) => {
            setDefinition({
              ...definition,
              cells: setCell(
                definition.cells,
                selected.channel,
                selected.locale,
                cell,
              ),
            });
            setDirty(true);
            setMessage(null);
          }}
        />
      )}
      <TemplatePreviewPanel templateKey={template.key} />
    </div>
  );
}

// TP-10
// TP-22
// TP-27
// TP-38
/** The template editor: the channel × locale matrix, a variant editor with its drafting helpers, the publication gate and channel-faithful previews. */
export function TemplateEditor({ templateKey }: { templateKey: string }) {
  const { t } = useI18n();
  const loaded = useGet<Template>(`/v1/templates/${enc(templateKey)}`);
  return (
    <section className="stack">
      <p>
        <Link to="/templates">{t("tpl.back")}</Link>
      </p>
      <h1>
        {loaded.state.kind === "ready" ? loaded.state.data.name : templateKey}
      </h1>
      <Loadable state={loaded.state} onRetry={loaded.reload}>
        {(template) => <Editor key={template.id} initial={template} />}
      </Loadable>
    </section>
  );
}
