import type { Channel, DeliveryStatus, SenderType } from "../api/types";
import type { MessageKey } from "../i18n/en";
import { useI18n } from "../i18n/i18n";

type Tone = "ok" | "warn" | "bad" | "info" | "neutral";

interface Presentation {
  label: MessageKey;
  tone: Tone;
  glyph: string;
}

const pushChannels: readonly Channel[] = ["push", "web_push"];

// X-6
// DS-13
// INV-5
export function presentStatus(
  status: DeliveryStatus,
  channel: Channel | null,
): Presentation {
  const push = channel !== null && pushChannels.includes(channel);
  switch (status) {
    case "queued":
      return { label: "status.queued", tone: "neutral", glyph: "…" };
    case "sent":
      return push
        ? { label: "status.pushAccepted", tone: "info", glyph: "→" }
        : { label: "status.sent", tone: "info", glyph: "→" };
    case "delivered":
      return push
        ? { label: "status.pushShown", tone: "ok", glyph: "✓" }
        : { label: "status.delivered", tone: "ok", glyph: "✓" };
    case "unknown_pending":
      return { label: "status.unknown_pending", tone: "warn", glyph: "?" };
    case "unknown":
      return { label: "status.unknown", tone: "warn", glyph: "?" };
    case "failed":
      return { label: "status.failed", tone: "bad", glyph: "✕" };
    case "skipped":
      return { label: "status.skipped", tone: "neutral", glyph: "–" };
    case "expired":
      return { label: "status.expired", tone: "bad", glyph: "⌛" };
    case "cancelled":
      return { label: "status.cancelled", tone: "neutral", glyph: "⊘" };
  }
}

/** A delivery's external projection with its text label; colour is never the only signal. */
export function StatusBadge({
  status,
  channel = null,
}: {
  status: DeliveryStatus;
  channel?: Channel | null;
}) {
  const { t } = useI18n();
  const view = presentStatus(status, channel);
  return (
    <span className={`badge tone-${view.tone}`} data-status={status}>
      <span aria-hidden="true">{view.glyph}</span>
      <span className="badge-label">{t(view.label)}</span>
    </span>
  );
}

// DS-12
export function ChannelSemantics({ channel }: { channel: Channel }) {
  const { t } = useI18n();
  return <p className="muted">{t(`semantics.${channel}`)}</p>;
}

export function ChannelLabel({ channel }: { channel: Channel }) {
  const { t } = useI18n();
  return <>{t(`channel.${channel}`)}</>;
}

const senderGlyph: Record<SenderType, string> = {
  human: "●",
  system: "■",
  agent: "◆",
};

// X-6
export function SenderTypeBadge({ type }: { type: SenderType }) {
  const { t } = useI18n();
  return (
    <span className="badge tone-neutral" data-sender-type={type}>
      <span aria-hidden="true">{senderGlyph[type]}</span>
      <span className="badge-label">{t(`sender.${type}`)}</span>
    </span>
  );
}

// X-6
// DS-32
export function OpenTrackingNotice() {
  const { t } = useI18n();
  return (
    <p className="notice" role="note">
      {t("engagement.openNotice")}
    </p>
  );
}

// X-6
// DS-32
export function ClickSplit({ human, bot }: { human: number; bot: number }) {
  const { t } = useI18n();
  return (
    <span className="row" role="group" aria-label={t("engagement.clicks")}>
      <span className="badge tone-ok">
        <span className="badge-label">
          {t("engagement.human", { count: human })}
        </span>
      </span>
      <span className="badge tone-neutral">
        <span className="badge-label">
          {t("engagement.bot", { count: bot })}
        </span>
      </span>
    </span>
  );
}

// X-6
export function FallbackTimezoneCount({ count }: { count: number }) {
  const { t } = useI18n();
  return (
    <span className="badge tone-warn">
      <span className="badge-label">
        {t("engagement.fallbackTimezone", { count })}
      </span>
    </span>
  );
}
