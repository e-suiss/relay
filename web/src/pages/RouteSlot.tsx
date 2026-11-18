import type { MessageKey } from "../i18n/en";
import { useI18n } from "../i18n/i18n";

export function RouteSlot({ area }: { area: MessageKey }) {
  const { t } = useI18n();
  return (
    <section className="stack">
      <h1>{t(area)}</h1>
      <p className="muted">{t("slot.body")}</p>
    </section>
  );
}
