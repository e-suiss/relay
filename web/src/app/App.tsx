import { useEffect, type ReactNode } from "react";
import { I18nProvider, useI18n, type Locale } from "../i18n/i18n";
import { NotFound } from "../pages/NotFound";
import { SignIn } from "../pages/SignIn";
import { SessionProvider, useSession } from "../session/session";
import { ThemeProvider } from "../theme/theme";
import { match, RouterProvider, useRouter } from "./router";
import { routes, type ConsoleRoute } from "./routes";
import { Shell } from "./Shell";

export function resolve(
  table: readonly ConsoleRoute[],
  path: string,
): ReactNode {
  for (const route of table) {
    const params = match(route.pattern, path);
    if (params !== null) return route.render(params);
  }
  return <NotFound />;
}

function Home() {
  const { navigate } = useRouter();
  useEffect(() => {
    navigate("/activity", { replace: true });
  }, [navigate]);
  return null;
}

function Content() {
  const { t } = useI18n();
  const { state, reload } = useSession();
  const { location } = useRouter();

  if (state.kind === "loading")
    return (
      <main className="center">
        <p role="status">{t("session.loading")}</p>
      </main>
    );
  if (state.kind === "signed_out") return <SignIn />;
  if (state.kind === "unavailable")
    return (
      <main className="center">
        <div className="panel stack" role="alert">
          <p>{t("session.unavailable")}</p>
          <button type="button" onClick={reload}>
            {t("session.retry")}
          </button>
        </div>
      </main>
    );
  return (
    <Shell>
      {location.path === "/" ? <Home /> : resolve(routes, location.path)}
    </Shell>
  );
}

export function App({ locale }: { locale?: Locale }) {
  return (
    <ThemeProvider>
      <I18nProvider {...(locale ? { locale } : {})}>
        <RouterProvider>
          <SessionProvider>
            <Content />
          </SessionProvider>
        </RouterProvider>
      </I18nProvider>
    </ThemeProvider>
  );
}
