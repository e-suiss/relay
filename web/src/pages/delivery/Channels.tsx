import { useId, useState, type SyntheticEvent } from "react";
import { useGet } from "../../api/hooks";
import type {
  ChannelCostQuote,
  ProviderAccountStatus,
} from "../../api/pending";
import type { ServerSchemas } from "../../api/types";
import {
  DataTable,
  KeyValues,
  Loadable,
  Mono,
  Section,
  Time,
  type Column,
} from "../../components/data";
import { PagedTable } from "../../components/ListScreen";
import { ChannelLabel } from "../../components/status";
import { useI18n } from "../../i18n/i18n";
import { formatMicros } from "../reports/Reports";

type ProviderAccount = ServerSchemas["ProviderAccount"];

function Breaker({ state }: { state: ProviderAccountStatus["circuit_breaker"]["provider"] }) {
  const { t } = useI18n();
  const tone = state === "closed" ? "ok" : state === "open" ? "bad" : "warn";
  return (
    <span className={`badge tone-${tone}`}>
      <span className="badge-label">{t(`channels.breaker.${state}`)}</span>
    </span>
  );
}

// CH-36
// X-6
function AccountStatus({ account }: { account: ProviderAccount }) {
  const { t } = useI18n();
  const status = useGet<ProviderAccountStatus>(
    `/v1/provider_accounts/${encodeURIComponent(account.id)}/status`,
  );
  return (
    <Loadable state={status.state} onRetry={status.reload}>
      {(data) => (
        <div className="stack">
          {data.data_residency.sends_data_abroad && (
            <p className="notice" role="note">
              {t("channels.abroad", {
                countries: data.data_residency.abroad_countries.join(", "),
              })}
            </p>
          )}
          {data.adapter.deprecation_warning && (
            <p className="notice" role="note">
              {t("channels.deprecated", {
                apis: data.adapter.deprecations
                  .map((item) =>
                    item.sunset_on ? `${item.api} (${item.sunset_on})` : item.api,
                  )
                  .join(", "),
              })}
            </p>
          )}
          <KeyValues
            items={[
              [
                t("channels.breakerProvider"),
                <Breaker key="p" state={data.circuit_breaker.provider} />,
              ],
              [
                t("channels.breakerAccount"),
                <Breaker key="a" state={data.circuit_breaker.account} />,
              ],
              [t("channels.adapterVersion"), data.adapter.adapter_version ?? "—"],
            ]}
          />
        </div>
      )}
    </Loadable>
  );
}

function AccountRow({ account }: { account: ProviderAccount }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  return (
    <li className="panel stack" data-provider-account={account.id}>
      <div className="row">
        <strong>
          <ChannelLabel channel={account.channel} />
        </strong>
        <Mono>{account.provider}</Mono>
        <span>{t(`channels.verification.${account.verification_state}`)}</span>
        {account.verification_rule_id && <Mono>{account.verification_rule_id}</Mono>}
        <span>{t(`channels.health.${account.health}`)}</span>
        {!account.in_installation && (
          <span className="badge tone-warn">
            <span aria-hidden="true">!</span>
            <span className="badge-label">{t("channels.abroadBadge")}</span>
          </span>
        )}
        <button
          type="button"
          aria-expanded={open}
          onClick={() => {
            setOpen(!open);
          }}
        >
          {open ? t("channels.hideStatus") : t("channels.showStatus")}
        </button>
      </div>
      <KeyValues
        items={[
          [t("channels.role"), account.role],
          [t("activity.state"), account.state],
          [t("channels.traffic"), account.traffic],
          [t("channels.verifiedAt"), <Time key="v" value={account.verified_at} />],
          [t("channels.healthAt"), <Time key="h" value={account.health_checked_at} />],
        ]}
      />
      {open && <AccountStatus account={account} />}
    </li>
  );
}

// CH-18
export function CostQuote() {
  const { t } = useI18n();
  const ids = { channel: useId(), country: useId(), quantity: useId(), category: useId() };
  const [draft, setDraft] = useState({
    channel: "sms",
    country: "TR",
    quantity: "1",
    category: "",
  });
  const [asked, setAsked] = useState<typeof draft | null>(null);
  const quote = useGet<ChannelCostQuote>(asked ? "/v1/channel_costs" : null, {
    channel: asked?.channel,
    country: asked?.country,
    quantity: asked?.quantity,
    category: asked?.category,
  });
  const submit = (event: SyntheticEvent<HTMLFormElement>) => {
    event.preventDefault();
    setAsked(draft);
  };
  const columns: Column<ChannelCostQuote["data"][number]>[] = [
    { key: "provider", header: t("history.provider"), render: (row) => row.provider },
    {
      key: "routable",
      header: t("channels.routable"),
      render: (row) => (row.routable ? t("common.yes") : t("common.no")),
    },
    {
      key: "unit",
      header: t("channels.unitPrice"),
      render: (row) =>
        row.priced
          ? `${formatMicros(
              row.unit_price_micros === null ? null : String(row.unit_price_micros),
              row.currency,
            )} / ${row.unit ?? "—"}`
          : t("channels.notPriced"),
    },
    {
      key: "total",
      header: t("reports.cost"),
      render: (row) =>
        formatMicros(
          row.total_micros === null ? null : String(row.total_micros),
          row.currency,
        ),
    },
  ];
  return (
    <Section title={t("channels.costTitle")}>
      <p className="muted">{t("channels.costIntro")}</p>
      <form className="row filters" onSubmit={submit}>
        <div className="field">
          <label htmlFor={ids.channel}>{t("why.channel")}</label>
          <select
            id={ids.channel}
            value={draft.channel}
            onChange={(event) => {
              setDraft({ ...draft, channel: event.target.value });
            }}
          >
            <option value="sms">{t("channel.sms")}</option>
            <option value="voice">{t("channel.voice")}</option>
            <option value="whatsapp">{t("channel.whatsapp")}</option>
          </select>
        </div>
        <div className="field">
          <label htmlFor={ids.country}>{t("reports.country")}</label>
          <input
            id={ids.country}
            value={draft.country}
            maxLength={2}
            onChange={(event) => {
              setDraft({ ...draft, country: event.target.value.toUpperCase() });
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.quantity}>{t("channels.quantity")}</label>
          <input
            id={ids.quantity}
            type="number"
            min={1}
            value={draft.quantity}
            onChange={(event) => {
              setDraft({ ...draft, quantity: event.target.value });
            }}
          />
        </div>
        <div className="field">
          <label htmlFor={ids.category}>{t("why.category")}</label>
          <input
            id={ids.category}
            value={draft.category}
            onChange={(event) => {
              setDraft({ ...draft, category: event.target.value.trim() });
            }}
          />
        </div>
        <button type="submit" className="primary">
          {t("channels.quote")}
        </button>
      </form>
      {asked && (
        <Loadable state={quote.state} onRetry={quote.reload}>
          {(data) => (
            <DataTable
              caption={t("channels.costTitle")}
              columns={columns}
              rows={data.data}
              rowKey={(row) => row.provider_account_id}
            />
          )}
        </Loadable>
      )}
    </Section>
  );
}

// CH-36
export function Channels() {
  const { t } = useI18n();
  return (
    <section className="stack">
      <h1>{t("nav.channels")}</h1>
      <PagedTable<ProviderAccount>
        title={t("channels.accounts")}
        path="/v1/provider_accounts"
        columns={[]}
        rowKey={(row) => row.id}
        after={(rows) => (
          <ul className="plain stack">
            {rows.map((account) => (
              <AccountRow key={account.id} account={account} />
            ))}
          </ul>
        )}
      />
      <CostQuote />
    </section>
  );
}
