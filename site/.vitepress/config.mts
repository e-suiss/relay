import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig, type DefaultTheme } from "vitepress";
import { en } from "./i18n/en.ts";

const sidebarFile = fileURLToPath(new URL("../reference/api/sidebar.json", import.meta.url));

function apiSidebar(): DefaultTheme.SidebarItem[] {
  if (!existsSync(sidebarFile)) return [];
  return JSON.parse(readFileSync(sidebarFile, "utf8")) as DefaultTheme.SidebarItem[];
}

const sdkItems: DefaultTheme.SidebarItem[] = [
  { text: "Overview", link: "/sdks/" },
  { text: "TypeScript and Node.js", link: "/sdks/typescript" },
  { text: ".NET", link: "/sdks/dotnet" },
  { text: "Java", link: "/sdks/java" },
  { text: "Elixir", link: "/sdks/elixir" },
  { text: "iOS (Swift)", link: "/sdks/swift" },
  { text: "Android (Kotlin)", link: "/sdks/kotlin" },
  { text: "React Native", link: "/sdks/react-native" },
  { text: "Flutter", link: "/sdks/flutter" },
];

export default defineConfig({
  lang: "en-US",
  title: "Relay",
  description: en["site.description"],
  cleanUrls: false,
  lastUpdated: false,
  srcExclude: ["examples/**", "skills/**", "e2e/**", "scripts/**", "README.md"],
  markdown: {
    theme: { light: "github-light-high-contrast", dark: "github-dark-high-contrast" },
  },
  themeConfig: {
    nav: [
      { text: en["nav.guide"], link: "/guide/getting-started" },
      { text: en["nav.agents"], link: "/agents/" },
      { text: en["nav.sdks"], link: "/sdks/" },
      { text: en["nav.reference"], link: "/reference/" },
    ],
    sidebar: {
      "/guide/": [
        {
          text: "Start here",
          items: [
            { text: "First notification in 5 minutes", link: "/guide/getting-started" },
            { text: "Local development", link: "/guide/local-development" },
            { text: "Concepts", link: "/guide/concepts" },
          ],
        },
        {
          text: "Sending and delivery",
          items: [
            { text: "Guarantees and idempotency", link: "/guide/guarantees" },
            { text: "Delivery semantics per channel", link: "/guide/delivery-semantics" },
            { text: "Why didn't they get it?", link: "/guide/decisions" },
            { text: "Webhooks", link: "/guide/webhooks" },
            { text: "Change data capture", link: "/guide/cdc" },
          ],
        },
        {
          text: "Tools",
          items: [
            { text: "Command line", link: "/guide/cli" },
            { text: "Translations", link: "/guide/translations" },
          ],
        },
      ],
      "/agents/": [
        {
          text: "Agents",
          items: [
            { text: "Overview", link: "/agents/" },
            { text: "Security guide", link: "/agents/security" },
            { text: "MCP server", link: "/agents/mcp" },
            { text: "Skills package", link: "/agents/skills" },
          ],
        },
      ],
      "/sdks/": [{ text: "SDKs", items: sdkItems }],
      "/reference/": [
        {
          text: "Reference",
          items: [
            { text: "Overview", link: "/reference/" },
            { text: "Limits, retries and guarantees", link: "/reference/limits" },
            { text: "Event catalog", link: "/reference/events" },
            { text: "Error codes", link: "/reference/errors" },
          ],
        },
        ...apiSidebar(),
      ],
    },
    socialLinks: [{ icon: "github", link: "https://github.com/e-suiss/relay" }],
    outline: { level: [2, 3], label: en["outline.label"] },
    docFooter: { prev: en["docFooter.prev"], next: en["docFooter.next"] },
    notFound: {
      title: en["notFound.title"],
      quote: en["notFound.quote"],
      linkText: en["notFound.link"],
      linkLabel: en["notFound.link"],
    },
    darkModeSwitchTitle: en["darkMode.switch"],
    returnToTopLabel: en.returnToTop,
    sidebarMenuLabel: en.sidebarMenu,
    footer: { message: en["footer.message"] },
  },
});
