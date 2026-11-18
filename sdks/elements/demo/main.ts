import { demoRelay } from "@esuiss/relay-react/testing";
import { configureRelay, defineRelayElements } from "../src/index.js";

const params = new URLSearchParams(window.location.search);
const locale = params.get("locale") ?? "en";
const scheme = params.get("scheme") === "dark" ? "dark" : "light";
const relay = demoRelay();

document.documentElement.lang = locale;
document.body.classList.toggle("dark", scheme === "dark");

configureRelay({
  baseUrl: "https://relay.example.com",
  token: relay.token,
  portalToken: relay.portalToken,
  fetch: relay.fetch,
  realtime: false,
  undoWindowMs: 2000,
  locale,
  colorScheme: scheme,
  links: {
    accessConsentUrl: "https://access.example.com/consents",
    accessApprovalOrigin: "https://access.example.com",
  },
});
defineRelayElements();

document.addEventListener("relay-open-preferences", (event) => {
  const category = (event as CustomEvent<{ category: string | null }>).detail.category;
  document.querySelector("relay-preference-center")?.setAttribute("focus-category", category ?? "");
});
