import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";

type Obj = Record<string, unknown>;

interface SidebarItem {
  text: string;
  link: string;
}

interface SidebarGroup {
  text: string;
  items: SidebarItem[];
}

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const contracts = resolve(site, "../contracts");
const out = join(site, "reference");
const repo = "https://github.com/e-suiss/relay/blob/main";

const families = [
  { key: "server", file: "openapi/server.yaml" },
  { key: "subscriber", file: "openapi/subscriber.yaml" },
  { key: "operator", file: "openapi/operator.yaml" },
] as const;

const methods = ["get", "post", "put", "patch", "delete"] as const;

const cache = new Map<string, unknown>();

function isObj(value: unknown): value is Obj {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function load(path: string): unknown {
  let document = cache.get(path);
  if (document === undefined) {
    document = parse(readFileSync(path, "utf8")) as unknown;
    cache.set(path, document);
  }
  return document;
}

function lookup(ref: string, base: string): { value: unknown; file: string } {
  const [target = "", pointer = ""] = ref.split("#");
  const file = target === "" ? base : resolve(dirname(base), target);
  let node = load(file);
  for (const token of pointer.split("/").filter((part) => part !== "")) {
    const key = token.replace(/~1/g, "/").replace(/~0/g, "~");
    node = isObj(node) ? node[key] : undefined;
  }
  return { value: node, file };
}

function deref(node: unknown, file: string): { value: Obj; file: string; name: string } {
  let value = node;
  let current = file;
  let name = "";
  for (let depth = 0; depth < 16 && isObj(value) && typeof value["$ref"] === "string"; depth++) {
    const ref = value["$ref"];
    name = ref.split("/").pop() ?? name;
    const found = lookup(ref, current);
    value = found.value;
    current = found.file;
  }
  return { value: isObj(value) ? value : {}, file: current, name };
}

const notId = "(?!(?:SHA|UTF|AES|P|ES|HS|RS|PS|EC|ISO)-)";
const idToken = `(?:§[\\d.]+|${notId}[A-Z]{1,4}-\\d+[a-z]?(?:\\s*\\(\\d+\\))?)`;
const idList = new RegExp(`\\s*\\(${idToken}(?:(?:,\\s*|\\s+and\\s+)${idToken})*\\)`, "g");

function clean(text: unknown): string {
  return str(text).replace(idList, "");
}

function esc(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/\{/g, "&#123;")
    .replace(/\}/g, "&#125;");
}

function prose(text: unknown): string {
  return esc(clean(text)).replace(/`([^`]+)`/g, "<code>$1</code>");
}

function heading(text: string): string {
  return esc(clean(text)).replace(/([\\*_[\]#|`])/g, "\\$1");
}

function slug(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function typeName(node: unknown, file: string, depth = 0): string {
  if (!isObj(node) || depth > 4) return "any";
  if (typeof node["$ref"] === "string") {
    const target = deref(node, file);
    const inner = typeName({ ...target.value, title: undefined }, target.file, depth + 1);
    return inner === "object" || inner === "any" ? target.name : `${inner}`;
  }
  for (const key of ["oneOf", "anyOf"]) {
    const options = node[key];
    if (Array.isArray(options)) {
      return options.map((option: unknown) => typeName(option, file, depth + 1)).join(" or ");
    }
  }
  if (Array.isArray(node["allOf"])) return "object";
  if ("const" in node) return JSON.stringify(node["const"]);
  const type = node["type"];
  if (Array.isArray(type)) return type.map(String).join(" or ");
  if (type === "array") return `${typeName(node["items"], file, depth + 1)}[]`;
  if (typeof type === "string") {
    const format = typeof node["format"] === "string" ? ` (${node["format"]})` : "";
    return `${type}${format}`;
  }
  return "any";
}

function enumValues(node: unknown, file: string): string {
  const target = isObj(node) && typeof node["$ref"] === "string" ? deref(node, file).value : node;
  if (!isObj(target) || !Array.isArray(target["enum"])) return "";
  const values = target["enum"].map((value: unknown) => `<code>${esc(String(value))}</code>`);
  return ` One of ${values.join(", ")}.`;
}

function properties(
  node: unknown,
  file: string,
): { props: Obj; required: Set<string>; file: string } {
  const target = deref(node, file);
  let props: Obj = isObj(target.value["properties"]) ? { ...target.value["properties"] } : {};
  const required = new Set<string>(
    Array.isArray(target.value["required"]) ? target.value["required"].map(String) : [],
  );
  if (Array.isArray(target.value["allOf"])) {
    for (const member of target.value["allOf"]) {
      const inner = properties(member, target.file);
      props = { ...props, ...inner.props };
      for (const name of inner.required) required.add(name);
    }
  }
  return { props, required, file: target.file };
}

function fieldTable(caption: string, node: unknown, file: string): string {
  const { props, required, file: where } = properties(node, file);
  const names = Object.keys(props);
  if (names.length === 0) return "";
  const rows = names.map((name) => {
    const prop = props[name];
    const described = isObj(prop) ? prop : {};
    const target =
      typeof described["$ref"] === "string" ? deref(described, where).value : described;
    const description = str(described["description"]) || str(target["description"]);
    return `<tr><td><code>${esc(name)}</code></td><td>${esc(typeName(prop, where))}</td><td>${required.has(name) ? "yes" : "no"}</td><td>${prose(description)}${enumValues(prop, where)}</td></tr>`;
  });
  return `<table tabindex="0"><caption>${esc(caption)}</caption><thead><tr><th scope="col">Field</th><th scope="col">Type</th><th scope="col">Required</th><th scope="col">Description</th></tr></thead><tbody>${rows.join("")}</tbody></table>`;
}

function html(block: string): string {
  return `<div v-pre class="relay-ref">${block}</div>`;
}

function security(operation: Obj): string {
  const entries = Array.isArray(operation["security"]) ? operation["security"] : null;
  if (entries === null) return "";
  if (entries.length === 0) return "<p><strong>Authentication:</strong> none.</p>";
  const parts = entries.filter(isObj).map((entry) =>
    Object.entries(entry)
      .map(([scheme, scopes]) => {
        const list = Array.isArray(scopes)
          ? scopes.map((s: unknown) => `<code>${esc(String(s))}</code>`)
          : [];
        return list.length > 0
          ? `<code>${esc(scheme)}</code> with ${list.join(", ")}`
          : `<code>${esc(scheme)}</code>`;
      })
      .join(" and "),
  );
  return `<p><strong>Authentication:</strong> ${parts.join("; or ")}.</p>`;
}

function parameters(pathItem: Obj, operation: Obj, file: string): string {
  const all = [
    ...(Array.isArray(pathItem["parameters"]) ? pathItem["parameters"] : []),
    ...(Array.isArray(operation["parameters"]) ? operation["parameters"] : []),
  ];
  if (all.length === 0) return "";
  const rows = all.map((raw: unknown) => {
    const { value, file: where } = deref(raw, file);
    return `<tr><td><code>${esc(str(value["name"]))}</code></td><td>${esc(str(value["in"]))}</td><td>${esc(typeName(value["schema"], where))}</td><td>${value["required"] === true ? "yes" : "no"}</td><td>${prose(value["description"])}${enumValues(value["schema"], where)}</td></tr>`;
  });
  return `<table tabindex="0"><caption>Parameters</caption><thead><tr><th scope="col">Name</th><th scope="col">In</th><th scope="col">Type</th><th scope="col">Required</th><th scope="col">Description</th></tr></thead><tbody>${rows.join("")}</tbody></table>`;
}

function requestBody(operation: Obj, file: string): string {
  if (!isObj(operation["requestBody"])) return "";
  const { value: body, file: where } = deref(operation["requestBody"], file);
  const content = isObj(body["content"]) ? body["content"] : {};
  const blocks = Object.entries(content).map(([type, media]) => {
    const schema = isObj(media) ? media["schema"] : undefined;
    const name =
      isObj(schema) && typeof schema["$ref"] === "string" ? deref(schema, where).name : "";
    const label = `Request body (${type}${name ? `, ${name}` : ""})`;
    return (
      fieldTable(label, schema, where) || `<p>${esc(label)}: ${esc(typeName(schema, where))}.</p>`
    );
  });
  const required = body["required"] === true ? "<p>The request body is required.</p>" : "";
  return required + blocks.join("");
}

function responses(operation: Obj, file: string): string {
  const all = isObj(operation["responses"]) ? operation["responses"] : {};
  const rows = Object.entries(all).map(([status, raw]) => {
    const { value, file: where } = deref(raw, file);
    const content = isObj(value["content"]) ? value["content"] : {};
    const schemas = Object.values(content)
      .map((media) => (isObj(media) ? media["schema"] : undefined))
      .filter((schema) => schema !== undefined)
      .map((schema) => esc(typeName(schema, where)));
    return `<tr><td><code>${esc(status)}</code></td><td>${prose(value["description"])}</td><td>${schemas.join(", ")}</td></tr>`;
  });
  if (rows.length === 0) return "";
  return `<table tabindex="0"><caption>Responses</caption><thead><tr><th scope="col">Status</th><th scope="col">Description</th><th scope="col">Body</th></tr></thead><tbody>${rows.join("")}</tbody></table>`;
}

function operationSection(
  path: string,
  method: string,
  pathItem: Obj,
  operation: Obj,
  file: string,
): string {
  const id = str(operation["operationId"]) || slug(`${method} ${path}`);
  const summary = str(operation["summary"]) || `${method.toUpperCase()} ${path}`;
  const body = [
    `<p><code>${method.toUpperCase()} ${esc(path)}</code> · operation <code>${esc(id)}</code></p>`,
    `<p>${prose(operation["description"])}</p>`,
    security(operation),
    parameters(pathItem, operation, file),
    requestBody(operation, file),
    responses(operation, file),
  ].join("");
  return `## ${heading(summary)} {#${id}}\n\n${html(body)}\n`;
}

function generateFamily(key: string, relative: string): SidebarGroup {
  const file = join(contracts, relative);
  const spec = load(file);
  if (!isObj(spec)) throw new Error(`${relative} is not a mapping`);
  const info = isObj(spec["info"]) ? spec["info"] : {};
  const title = str(info["title"]) || key;
  const tags = (Array.isArray(spec["tags"]) ? spec["tags"] : []).filter(isObj);
  const byTag = new Map<string, string[]>();
  const paths = isObj(spec["paths"]) ? spec["paths"] : {};
  for (const [path, rawItem] of Object.entries(paths)) {
    if (!isObj(rawItem)) continue;
    for (const method of methods) {
      const operation = rawItem[method];
      if (!isObj(operation)) continue;
      const tag =
        Array.isArray(operation["tags"]) && typeof operation["tags"][0] === "string"
          ? operation["tags"][0]
          : "other";
      const sections = byTag.get(tag) ?? [];
      sections.push(operationSection(path, method, rawItem, operation, file));
      byTag.set(tag, sections);
    }
  }
  const order = [...tags.map((tag) => str(tag["name"])), ...byTag.keys()].filter(
    (name, index, list) => byTag.has(name) && list.indexOf(name) === index,
  );
  const dir = join(out, "api", key);
  mkdirSync(dir, { recursive: true });
  const items: SidebarItem[] = [];
  const rows: string[] = [];
  for (const tag of order) {
    const description = str(tags.find((entry) => entry["name"] === tag)?.["description"]);
    const sections = byTag.get(tag) ?? [];
    const page = slug(tag);
    const intro = description ? `${html(`<p>${prose(description)}</p>`)}\n\n` : "";
    writeFileSync(
      join(dir, `${page}.md`),
      `---\noutline: [2, 2]\n---\n\n# ${heading(title)}: ${heading(tag)}\n\n${intro}${sections.join("\n")}`,
    );
    items.push({ text: tag, link: `/reference/api/${key}/${page}` });
    rows.push(
      `<tr><td><a href="/reference/api/${key}/${page}.html">${esc(tag)}</a></td><td>${sections.length}</td><td>${prose(description)}</td></tr>`,
    );
  }
  writeFileSync(
    join(dir, "index.md"),
    `# ${heading(title)}\n\n${html(
      `<p>${prose(info["description"])}</p><p>Contract version <code>${esc(str(info["version"]))}</code>, rendered from <a href="${repo}/contracts/${relative}">contracts/${esc(relative)}</a>.</p><table tabindex="0"><caption>Operation groups</caption><thead><tr><th scope="col">Group</th><th scope="col">Operations</th><th scope="col">Description</th></tr></thead><tbody>${rows.join("")}</tbody></table>`,
    )}\n`,
  );
  return {
    text: title,
    items: [{ text: "Overview", link: `/reference/api/${key}/` }, ...items],
  };
}

const eventIds = new Set<string>();

function uniqueId(base: string): string {
  let id = base;
  for (let n = 2; eventIds.has(id); n++) id = `${base}-${n}`;
  eventIds.add(id);
  return id;
}

function messageSection(channel: string, name: string, raw: unknown, file: string): string {
  const { value: message, file: where } = deref(raw, file);
  const eventName = str(message["name"]) || name;
  const version = message["x-relay-schema-version"];
  const payload = isObj(message["payload"]) ? message["payload"] : {};
  const schema = isObj(payload["schema"]) ? payload["schema"] : payload;
  const members = Array.isArray(schema["allOf"]) ? schema["allOf"] : [schema];
  let data: unknown;
  for (const member of members) {
    const { props, file: memberFile } = properties(member, where);
    if (props["data"] !== undefined) data = { node: props["data"], file: memberFile };
  }
  const table = isObj(data) ? fieldTable("Data fields", data["node"], str(data["file"])) : "";
  const meta = typeof version === "number" ? `<p>Data schema version ${version}.</p>` : "";
  return `### ${heading(eventName)} {#${uniqueId(slug(`${channel}-${name}`))}}\n\n${html(`<p>${prose(message["summary"] ?? message["description"])}</p>${meta}${table}`)}\n`;
}

function profile(channel: Obj): string {
  const spec = isObj(channel["x-relay-webhook-profile"])
    ? channel["x-relay-webhook-profile"]
    : null;
  if (spec === null) return "";
  const headerRows = (group: unknown) =>
    Object.entries(isObj(group) ? group : {})
      .map(([key, text]) => `<tr><td><code>${esc(key)}</code></td><td>${prose(text)}</td></tr>`)
      .join("");
  const rules = Array.isArray(spec["consumer_rules"]) ? spec["consumer_rules"] : [];
  return [
    `<table tabindex="0"><caption>Signed delivery headers</caption><thead><tr><th scope="col">Header</th><th scope="col">Meaning</th></tr></thead><tbody>${headerRows(spec["headers"])}</tbody></table>`,
    `<p>Signed content: <code>${esc(str(spec["signed_content"]))}</code></p>`,
    `<table tabindex="0"><caption>Signature schemes</caption><thead><tr><th scope="col">Scheme</th><th scope="col">Meaning</th></tr></thead><tbody>${headerRows(spec["schemes"])}</tbody></table>`,
    `<table tabindex="0"><caption>Unsigned convenience headers</caption><thead><tr><th scope="col">Header</th><th scope="col">Meaning</th></tr></thead><tbody>${headerRows(spec["unsigned_headers"])}</tbody></table>`,
    `<p>Consumer rules:</p><ul>${rules.map((rule: unknown) => `<li>${prose(rule)}</li>`).join("")}</ul>`,
  ].join("");
}

function generateEvents(): void {
  const file = join(contracts, "asyncapi/events.yaml");
  const spec = load(file);
  if (!isObj(spec)) throw new Error("events.yaml is not a mapping");
  const info = isObj(spec["info"]) ? spec["info"] : {};
  const channels = isObj(spec["channels"]) ? spec["channels"] : {};
  const sections = Object.entries(channels)
    .filter(([, channel]) => isObj(channel))
    .map(([key, raw]) => {
      const channel = raw as Obj;
      const messages = isObj(channel["messages"]) ? channel["messages"] : {};
      const list = Object.entries(messages).map(([name, message]) =>
        messageSection(key, name, message, file),
      );
      return `## ${heading(str(channel["title"]) || key)} {#${slug(key)}}\n\n${html(`<p>${prose(channel["description"])}</p>${profile(channel)}`)}\n\n${list.join("\n")}`;
    });
  writeFileSync(
    join(out, "events.md"),
    `---\noutline: [2, 2]\n---\n\n# Event catalog\n\n${html(`<p>${prose(info["description"])}</p><p>Catalog version <code>${esc(str(info["version"]))}</code>, rendered from <a href="${repo}/contracts/asyncapi/events.yaml">contracts/asyncapi/events.yaml</a>.</p>`)}\n\n${sections.join("\n")}`,
  );
}

function generateErrors(): void {
  const catalog = load(join(contracts, "errors.yaml"));
  if (!isObj(catalog)) throw new Error("errors.yaml is not a mapping");
  const defaults = (
    Array.isArray(catalog["retryable_defaults"]) ? catalog["retryable_defaults"] : []
  ).filter(isObj);
  const codes = (Array.isArray(catalog["codes"]) ? catalog["codes"] : []).filter(isObj);
  const defaultRows = defaults
    .map(
      (row) =>
        `<tr><td>${esc(String(row["status"]))}</td><td>${row["code"] ? `<code>${esc(str(row["code"]))}</code>` : "any"}</td><td>${row["retryable"] === true ? "yes" : "no"}</td></tr>`,
    )
    .join("");
  const families = new Map<string, Obj[]>();
  for (const code of codes) {
    const family = str(code["family"]) || "other";
    families.set(family, [...(families.get(family) ?? []), code]);
  }
  const sections = [...families.entries()].map(([family, list]) => {
    const rows = list
      .map(
        (code) =>
          `<tr><td id="${esc(str(code["code"]))}"><code>${esc(str(code["code"]))}</code></td><td>${esc(String(code["status"]))}</td><td>${code["retryable"] === true ? "yes" : "no"}</td><td><strong>${esc(str(code["title"]))}.</strong> ${prose(code["description"])}</td></tr>`,
      )
      .join("");
    return `## ${heading(family)} {#family-${slug(family)}}\n\n${html(`<table tabindex="0"><caption>Codes of the ${esc(family)} family</caption><thead><tr><th scope="col">Code</th><th scope="col">Status</th><th scope="col">Retryable</th><th scope="col">Meaning</th></tr></thead><tbody>${rows}</tbody></table>`)}\n`;
  });
  writeFileSync(
    join(out, "errors.md"),
    `---\noutline: [2, 2]\n---\n\n# Error codes\n\n${html(`<p>Every error is an RFC 9457 problem document. Its <code>type</code> resolves to <code>/v1/errors/&#123;code&#125;</code> on the same region, and <code>retryable</code> tells a client whether to try again. Rendered from <a href="${repo}/contracts/errors.yaml">contracts/errors.yaml</a>.</p><table tabindex="0"><caption>Retry defaults by status</caption><thead><tr><th scope="col">Status</th><th scope="col">Code</th><th scope="col">Retryable</th></tr></thead><tbody>${defaultRows}</tbody></table>`)}\n\n${sections.join("\n")}`,
  );
}

rmSync(join(out, "api"), { recursive: true, force: true });
mkdirSync(join(out, "api"), { recursive: true });
const sidebar = families.map((family) => generateFamily(family.key, family.file));
writeFileSync(join(out, "api", "sidebar.json"), `${JSON.stringify(sidebar, null, 2)}\n`);
generateEvents();
generateErrors();
console.log(
  `reference: ${sidebar.reduce((sum, group) => sum + group.items.length - 1, 0)} API pages, events and errors`,
);
