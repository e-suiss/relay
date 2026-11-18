import { StrictMode, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Inbox,
  InboxPopover,
  PreferenceCenter,
  RelayProvider,
  Toaster,
  WebhookPortal,
  type ColorScheme,
  type ConsentView,
} from "../src/index.js";
import { demoRelay } from "../src/testing/index.js";

const params = new URLSearchParams(window.location.search);
const locale = params.get("locale") ?? "en";
const scheme = (params.get("scheme") ?? "light") as ColorScheme;
const view = params.get("view") ?? "all";
const relay = demoRelay();
const consents = (): Promise<readonly ConsentView[] | null> =>
  Promise.resolve(params.get("consents") === "none" ? null : [{ channel: "email", status: "none" }]);
document.documentElement.lang = locale;
document.body.style.margin = "0";
document.body.style.background = scheme === "dark" ? "#111418" : "#ffffff";

function Demo() {
  const [focus, setFocus] = useState<string | null>(null);
  return (
    <RelayProvider
      baseUrl="https://relay.example.com"
      token={relay.token}
      portalToken={relay.portalToken}
      fetch={relay.fetch}
      realtime={false}
      tabs={false}
      storage={null}
      undoWindowMs={2000}
      locale={locale}
      colorScheme={scheme}
      brand={{ name: "Example Shop", theme: { accent: "#0b5c3b" } }}
      links={{
        accessConsentUrl: "https://access.example.com/consents",
        accessApprovalOrigin: "https://access.example.com",
        onOpenPreferences: (category) => setFocus(category),
      }}
    >
      <h1 style={{ fontFamily: "system-ui", padding: "0 16px", color: scheme === "dark" ? "#f1f3f5" : "#1b1f24" }}>
        Relay components
      </h1>
      <div style={{ padding: "0 16px", display: "grid", gap: "24px" }}>
        {view === "all" || view === "inbox" ? (
          <>
            <InboxPopover tags={["shipping"]} />
            <Inbox tags={["shipping"]} />
          </>
        ) : null}
        {view === "all" || view === "preferences" ? (
          <PreferenceCenter focusCategory={focus} consents={consents} />
        ) : null}
        {view === "all" || view === "portal" ? <WebhookPortal /> : null}
      </div>
      <Toaster />
    </RelayProvider>
  );
}

const root = document.getElementById("root");
if (root !== null) {
  createRoot(root).render(
    <StrictMode>
      <Demo />
    </StrictMode>,
  );
}
