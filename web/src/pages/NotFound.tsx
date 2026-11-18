import { useI18n } from "../i18n/i18n";

export function NotFound() {
  const { t } = useI18n();
  return (
    <section className="stack">
      <h1>{t("notFound.title")}</h1>
      <p>{t("notFound.body")}</p>
    </section>
  );
}
