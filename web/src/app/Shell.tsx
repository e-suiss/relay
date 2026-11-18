import { useId, type ReactNode } from "react";
import { locales, useI18n, type Locale } from "../i18n/i18n";
import { useSession } from "../session/session";
import { themes, useTheme, type Theme } from "../theme/theme";
import { ActiveKillSwitches } from "../pages/governance/KillSwitches";
import { ContextBar } from "./ContextBar";
import { Link, useRouter } from "./router";
import { navigation, type NavGroup, type NavItem } from "./routes";

const groups: readonly NavGroup[] = [
  "nav.group.activity",
  "nav.group.build",
  "nav.group.audience",
  "nav.group.delivery",
  "nav.group.governance",
  "nav.group.operator",
];

function active(path: string, to: string): boolean {
  return path === to || path.startsWith(`${to}/`);
}

function NavLink({ item }: { item: NavItem }) {
  const { t } = useI18n();
  const { location } = useRouter();
  if (item.external === true) return <a href={item.to}>{t(item.label)}</a>;
  return (
    <Link
      to={item.to}
      aria-current={active(location.path, item.to) ? "page" : undefined}
    >
      {t(item.label)}
    </Link>
  );
}

function Tools() {
  const { t, locale, setLocale } = useI18n();
  const { theme, setTheme } = useTheme();
  const { state, signOut } = useSession();
  const localeId = useId();
  const themeId = useId();
  return (
    <div className="header-tools">
      <div className="field">
        <label htmlFor={localeId}>{t("locale.label")}</label>
        <select
          id={localeId}
          value={locale}
          onChange={(event) => {
            setLocale(event.target.value as Locale);
          }}
        >
          {locales.map((item) => (
            <option key={item} value={item} lang={item}>
              {item === "tr" ? "Türkçe" : "English"}
            </option>
          ))}
        </select>
      </div>
      <div className="field">
        <label htmlFor={themeId}>{t("theme.label")}</label>
        <select
          id={themeId}
          value={theme}
          onChange={(event) => {
            setTheme(event.target.value as Theme);
          }}
        >
          {themes.map((item) => (
            <option key={item} value={item}>
              {t(`theme.${item}`)}
            </option>
          ))}
        </select>
      </div>
      {state.kind === "ready" && (
        <span className="stack">
          <span className="muted">
            {t("session.operator", {
              name: state.session.operator.display_name,
            })}
          </span>
          <button
            type="button"
            onClick={() => {
              void signOut();
            }}
          >
            {t("session.signOut")}
          </button>
        </span>
      )}
    </div>
  );
}

export function Shell({ children }: { children: ReactNode }) {
  const { t } = useI18n();
  const { installationOperator } = useSession();
  const visible = navigation.filter(
    (item) => item.operator !== true || installationOperator,
  );
  return (
    <div className="shell">
      <a className="skip-link" href="#main">
        {t("app.skip")}
      </a>
      <header className="shell-header">
        <p className="brand">{t("app.title")}</p>
        <ContextBar />
        <Tools />
        <ActiveKillSwitches />
      </header>
      <nav className="shell-nav" aria-label={t("nav.label")}>
        {groups.map((group) => {
          const items = visible.filter((item) => item.group === group);
          if (items.length === 0) return null;
          return (
            <div key={group}>
              <h2>{t(group)}</h2>
              <ul>
                {items.map((item) => (
                  <li key={item.to}>
                    <NavLink item={item} />
                  </li>
                ))}
              </ul>
            </div>
          );
        })}
      </nav>
      <main id="main" className="shell-main" tabIndex={-1}>
        {children}
      </main>
    </div>
  );
}
