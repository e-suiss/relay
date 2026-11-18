import { readFileSync, writeFileSync } from "node:fs";
import { parse } from "yaml";

const contracts = new URL("../../../contracts/", import.meta.url);
const generated = new URL("../src/generated/", import.meta.url);
const methods = ["get", "post", "put", "patch", "delete"];
const header = "// X-48\n";

function read(path) {
  return parse(readFileSync(new URL(path, contracts), "utf8"));
}

function idempotency(refs) {
  if (refs.some((ref) => ref.endsWith("#/IdempotencyKey"))) return "required";
  if (refs.some((ref) => ref.endsWith("#/IdempotencyKeyCloudEvents"))) return "optional";
  return "none";
}

function operations(file) {
  const doc = read(`openapi/${file}`);
  const table = {};
  for (const [path, item] of Object.entries(doc.paths)) {
    for (const method of methods) {
      const operation = item[method];
      if (!operation) continue;
      const parameters = [...(item.parameters ?? []), ...(operation.parameters ?? [])];
      const refs = parameters.map((parameter) => parameter.$ref ?? "");
      const content = operation.requestBody?.content;
      table[operation.operationId] = {
        method: method.toUpperCase(),
        path,
        idempotency: idempotency(refs),
        paginated: refs.some((ref) => ref.endsWith("#/StartingAfter")),
        contentType: content ? Object.keys(content)[0] : null,
      };
    }
  }
  const sorted = Object.fromEntries(Object.entries(table).sort(([a], [b]) => a.localeCompare(b)));
  return { version: doc.info.version, table: sorted };
}

function write(name, body) {
  writeFileSync(new URL(name, generated), header + body);
}

const server = operations("server.yaml");
const subscriber = operations("subscriber.yaml");
if (server.version !== subscriber.version) {
  console.error(`API versions differ: ${server.version} and ${subscriber.version}`);
  process.exit(1);
}

write(
  "operations.ts",
  [
    `export const serverOperations = ${JSON.stringify(server.table)} as const;`,
    `export const subscriberOperations = ${JSON.stringify(subscriber.table)} as const;`,
    "",
  ].join("\n"),
);

const errors = read("errors.yaml");
const catalog = Object.fromEntries(
  errors.codes.map((entry) => [
    entry.code,
    { family: entry.family, status: entry.status, retryable: entry.retryable },
  ]),
);
const defaults = errors.retryable_defaults.map((entry) => ({
  status: entry.status,
  code: entry.code ?? null,
  retryable: entry.retryable,
}));

write(
  "errors.ts",
  [
    `export const errorCatalog: Readonly<Record<string, { readonly family: string; readonly status: number; readonly retryable: boolean }>> = ${JSON.stringify(catalog)};`,
    `export const retryableDefaults: ReadonlyArray<{ readonly status: number; readonly code: string | null; readonly retryable: boolean }> = ${JSON.stringify(defaults)};`,
    "",
  ].join("\n"),
);

write("meta.ts", `export const API_VERSION = ${JSON.stringify(server.version)};\n`);
