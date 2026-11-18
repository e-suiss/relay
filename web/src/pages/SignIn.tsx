import { loginUrl } from "../api/client";
import { href, useRouter } from "../app/router";
import { useI18n } from "../i18n/i18n";

// X-3
// X-47
export function SignIn() {
  const { t } = useI18n();
  const { location } = useRouter();
  const query = location.search.toString();
  const returnTo = href(location.path) + (query ? `?${query}` : "");
  return (
    <main className="center">
      <section className="panel stack">
        <h1>{t("session.signInTitle")}</h1>
        <p>{t("session.signInBody")}</p>
        <a className="button primary" href={loginUrl(returnTo)}>
          {t("session.signIn")}
        </a>
      </section>
    </main>
  );
}
