package app.suiss.relay.generator;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/** Writes the generated layer of the Java SDK from the Relay server contract. */
public final class Generator {
  private static final String PACKAGE = "app.suiss.relay";
  private static final String GENERATED =
      "@javax.annotation.processing.Generated(\"app.suiss.relay.generator.Generator\")";
  private static final List<String> METHODS = List.of("get", "post", "put", "patch", "delete");
  private static final Pattern PATH_PARAM = Pattern.compile("\\{([A-Za-z0-9_]+)\\}");

  private Generator() {}

  record Query(String name, String kind, boolean required) {}

  record Op(
      String id,
      String method,
      String path,
      String summary,
      List<String> pathParams,
      List<Query> query,
      String idempotency,
      String ifMatch,
      String body,
      String contentType,
      String response,
      boolean paginated) {}

  /**
   * Generates the SDK sources.
   *
   * @param args the contracts directory and the Java source root
   * @throws IOException when a file cannot be read or written
   */
  public static void main(String[] args) throws IOException {
    Path contracts = Path.of(args[0]);
    Path sources = Path.of(args[1]);
    ObjectMapper yaml = new ObjectMapper(new YAMLFactory());
    JsonNode server = yaml.readTree(contracts.resolve("openapi/server.yaml").toFile());
    JsonNode parameters =
        yaml.readTree(contracts.resolve("openapi/components/parameters.yaml").toFile());
    JsonNode schemas = yaml.readTree(contracts.resolve("openapi/components/schemas.yaml").toFile());
    JsonNode errors = yaml.readTree(contracts.resolve("errors.yaml").toFile());

    List<Op> ops = operations(server, parameters, schemas);
    Path base = sources.resolve(PACKAGE.replace('.', '/'));
    Path params = base.resolve("params");
    Files.createDirectories(params);
    try (Stream<Path> existing = Files.list(params)) {
      for (Path file : existing.toList()) {
        String name = file.getFileName().toString();
        if (name.endsWith("Params.java") && !name.equals("QueryParams.java")) {
          Files.delete(file);
        }
      }
    }

    write(base.resolve("ApiVersion.java"), apiVersion(server.path("info").path("version").asText()));
    write(base.resolve("ErrorCatalog.java"), errorCatalog(errors));
    write(base.resolve("RelayApi.java"), api(ops));
    for (Op op : ops) {
      if (!op.query().isEmpty()) {
        write(params.resolve(paramsClass(op) + ".java"), paramsSource(op));
      }
    }
  }

  private static void write(Path file, String content) throws IOException {
    Files.writeString(file, content, StandardCharsets.UTF_8);
  }

  private static List<Op> operations(JsonNode server, JsonNode parameters, JsonNode schemas) {
    List<Op> ops = new ArrayList<>();
    for (Map.Entry<String, JsonNode> entry : server.path("paths").properties()) {
      String path = entry.getKey();
      for (Map.Entry<String, JsonNode> m : entry.getValue().properties()) {
        if (!METHODS.contains(m.getKey()) || !bearer(m.getValue())) {
          continue;
        }
        ops.add(operation(path, m.getKey(), m.getValue(), parameters, schemas));
      }
    }
    return ops;
  }

  private static boolean bearer(JsonNode op) {
    for (JsonNode requirement : op.path("security")) {
      if (requirement.has("access_bearer")) {
        return true;
      }
    }
    return false;
  }

  private static Op operation(
      String path, String method, JsonNode op, JsonNode parameters, JsonNode schemas) {
    List<String> pathParams = new ArrayList<>();
    Matcher matcher = PATH_PARAM.matcher(path);
    while (matcher.find()) {
      pathParams.add(matcher.group(1));
    }
    List<Query> query = new ArrayList<>();
    String idempotency = "NONE";
    String ifMatch = "NONE";
    boolean paginated = false;
    for (JsonNode parameter : op.path("parameters")) {
      String ref = parameter.path("$ref").asText("");
      String refName = ref.isEmpty() ? "" : ref.substring(ref.indexOf("#/") + 2);
      JsonNode resolved = ref.isEmpty() ? parameter : parameters.path(refName);
      switch (refName) {
        case "IdempotencyKey" -> idempotency = "REQUIRED";
        case "IdempotencyKeyCloudEvents" -> idempotency = "OPTIONAL";
        case "IfMatch" -> ifMatch = "REQUIRED";
        case "IfMatchOptional" -> ifMatch = "OPTIONAL";
        case "StartingAfter" -> paginated = true;
        default -> {}
      }
      if (resolved.path("in").asText().equals("query")) {
        query.add(
            new Query(
                resolved.path("name").asText(),
                kind(resolved.path("schema"), schemas),
                resolved.path("required").asBoolean(false)));
      }
    }
    JsonNode requestBody = op.path("requestBody");
    String body = "NONE";
    String contentType = "application/json";
    if (!requestBody.isMissingNode()) {
      body = requestBody.path("required").asBoolean(false) ? "REQUIRED" : "OPTIONAL";
      Iterator<Map.Entry<String, JsonNode>> types =
          requestBody.path("content").properties().iterator();
      if (types.hasNext()) {
        contentType = types.next().getKey();
      }
    }
    String response = "JSON";
    for (Map.Entry<String, JsonNode> r : op.path("responses").properties()) {
      if (r.getKey().startsWith("2")) {
        Iterator<Map.Entry<String, JsonNode>> types =
            r.getValue().path("content").properties().iterator();
        if (types.hasNext() && types.next().getKey().startsWith("text/")) {
          response = "TEXT";
        }
        break;
      }
    }
    return new Op(
        op.path("operationId").asText(),
        method.toUpperCase(Locale.ROOT),
        path,
        op.path("summary").asText(op.path("operationId").asText()),
        pathParams,
        query,
        idempotency,
        ifMatch,
        body,
        contentType,
        response,
        paginated && method.equals("get"));
  }

  private static String kind(JsonNode schema, JsonNode schemas) {
    String type = schema.path("type").asText("");
    if (type.isEmpty() && schema.has("$ref")) {
      String ref = schema.path("$ref").asText();
      JsonNode target = schemas.path(ref.substring(ref.indexOf("#/") + 2));
      type = target.path("type").asText("");
    }
    return switch (type) {
      case "integer" -> "integer";
      case "boolean" -> "boolean";
      case "array" -> "array";
      default -> "string";
    };
  }

  private static String apiVersion(String version) {
    return "package "
        + PACKAGE
        + ";\n\n/** The Relay API version this SDK is pinned to. */\n"
        + GENERATED
        + "\npublic final class ApiVersion {\n"
        + "  /** The dated API version sent as {@code Relay-Version} on every request. */\n"
        + "  public static final String VALUE = "
        + literal(version)
        + ";\n\n  private ApiVersion() {}\n}\n";
  }

  private static String errorCatalog(JsonNode errors) {
    StringBuilder out = new StringBuilder();
    out.append("package ").append(PACKAGE).append(";\n\n");
    out.append("import java.util.List;\nimport java.util.Map;\n\n");
    out.append(GENERATED).append("\nfinal class ErrorCatalog {\n");
    out.append("  record Entry(String family, int status, boolean retryable) {}\n\n");
    out.append("  record Default(int status, String code, boolean retryable) {}\n\n");
    out.append("  static final Map<String, Entry> CODES =\n      Map.ofEntries(\n");
    List<String> entries = new ArrayList<>();
    for (JsonNode code : errors.path("codes")) {
      entries.add(
          "          Map.entry("
              + literal(code.path("code").asText())
              + ", new Entry("
              + literal(code.path("family").asText())
              + ", "
              + code.path("status").asInt()
              + ", "
              + code.path("retryable").asBoolean()
              + "))");
    }
    out.append(String.join(",\n", entries)).append(");\n\n");
    out.append("  static final List<Default> DEFAULTS =\n      List.of(\n");
    List<String> defaults = new ArrayList<>();
    for (JsonNode d : errors.path("retryable_defaults")) {
      defaults.add(
          "          new Default("
              + d.path("status").asInt()
              + ", "
              + (d.has("code") ? literal(d.path("code").asText()) : "null")
              + ", "
              + d.path("retryable").asBoolean()
              + ")");
    }
    out.append(String.join(",\n", defaults)).append(");\n\n");
    out.append("  private ErrorCatalog() {}\n}\n");
    return out.toString();
  }

  private static String api(List<Op> ops) {
    StringBuilder out = new StringBuilder();
    out.append("package ").append(PACKAGE).append(";\n\n");
    out.append("import app.suiss.relay.params.*;\n");
    out.append("import com.fasterxml.jackson.databind.JsonNode;\n");
    out.append("import java.util.List;\n\n");
    out.append("/** Every operation of the Relay server API that an API client calls. */\n");
    out.append(GENERATED).append("\npublic final class RelayApi {\n");
    for (Op op : ops) {
      out.append("  private static final Operation ")
          .append(constant(op.id()))
          .append(" =\n      new Operation(\n");
      out.append("          ").append(literal(op.id())).append(",\n");
      out.append("          ").append(literal(op.method())).append(",\n");
      out.append("          ").append(literal(op.path())).append(",\n");
      out.append("          Operation.Presence.").append(op.idempotency()).append(",\n");
      out.append("          Operation.Presence.").append(op.ifMatch()).append(",\n");
      out.append("          Operation.Presence.").append(op.body()).append(",\n");
      out.append("          ").append(literal(op.contentType())).append(",\n");
      out.append("          Operation.Response.").append(op.response()).append(");\n");
    }
    out.append("\n  private final Requester requester;\n\n");
    out.append("  RelayApi(Requester requester) {\n    this.requester = requester;\n  }\n");
    for (Op op : ops) {
      method(out, op, true);
      if (!minimalSignature(op).equals(fullSignature(op))) {
        method(out, op, false);
      }
    }
    out.append("}\n");
    return out.toString();
  }

  private static List<String> fullSignature(Op op) {
    List<String> args = new ArrayList<>();
    for (String p : op.pathParams()) {
      args.add("String " + camel(p));
    }
    if (!op.query().isEmpty()) {
      args.add(paramsClass(op) + " params");
    }
    if (!op.body().equals("NONE")) {
      args.add("JsonNode body");
    }
    args.add("RequestOptions options");
    return args;
  }

  private static List<String> minimalSignature(Op op) {
    List<String> args = new ArrayList<>();
    for (String p : op.pathParams()) {
      args.add("String " + camel(p));
    }
    if (op.query().stream().anyMatch(Query::required)) {
      args.add(paramsClass(op) + " params");
    }
    if (op.body().equals("REQUIRED")) {
      args.add("JsonNode body");
    }
    return args;
  }

  private static void method(StringBuilder out, Op op, boolean full) {
    String returns = op.paginated() ? "Page" : op.response().equals("TEXT") ? "String" : "JsonNode";
    List<String> signature = full ? fullSignature(op) : minimalSignature(op);
    out.append("\n  /**\n   * ").append(javadoc(op.summary())).append(".\n");
    out.append("   *\n   * <p>{@code ")
        .append(op.method())
        .append(" ")
        .append(op.path())
        .append("}\n");
    for (String arg : signature) {
      String name = arg.substring(arg.indexOf(' ') + 1);
      out.append("   * @param ").append(name).append(" ").append(paramDoc(name)).append("\n");
    }
    out.append("   * @return ").append(returnDoc(returns)).append("\n   */\n");
    out.append("  public ")
        .append(returns)
        .append(" ")
        .append(op.id())
        .append("(")
        .append(String.join(", ", signature))
        .append(") {\n");
    if (full) {
      String pathList =
          op.pathParams().isEmpty()
              ? "List.of()"
              : "List.of("
                  + String.join(", ", op.pathParams().stream().map(Generator::camel).toList())
                  + ")";
      String params = op.query().isEmpty() ? "null" : "params";
      String body = op.body().equals("NONE") ? "null" : "body";
      String call =
          op.paginated()
              ? "requester.page(" + constant(op.id()) + ", " + pathList + ", " + params + ", options)"
              : op.response().equals("TEXT")
                  ? "requester.text("
                      + constant(op.id())
                      + ", "
                      + pathList
                      + ", "
                      + params
                      + ", "
                      + body
                      + ", options)"
                  : "requester.json("
                      + constant(op.id())
                      + ", "
                      + pathList
                      + ", "
                      + params
                      + ", "
                      + body
                      + ", options)";
      out.append("    return ").append(call).append(";\n  }\n");
    } else {
      List<String> args = new ArrayList<>();
      for (String p : op.pathParams()) {
        args.add(camel(p));
      }
      if (!op.query().isEmpty()) {
        args.add(op.query().stream().anyMatch(Query::required) ? "params" : "null");
      }
      if (!op.body().equals("NONE")) {
        args.add(op.body().equals("REQUIRED") ? "body" : "null");
      }
      args.add("RequestOptions.none()");
      out.append("    return ")
          .append(op.id())
          .append("(")
          .append(String.join(", ", args))
          .append(");\n  }\n");
    }
  }

  private static String paramDoc(String name) {
    return switch (name) {
      case "params" -> "the query parameters";
      case "body" -> "the request body";
      case "options" -> "the request options";
      default -> "the {@code " + snake(name) + "} path parameter";
    };
  }

  private static String returnDoc(String returns) {
    return switch (returns) {
      case "Page" -> "the first page; further pages are fetched lazily";
      case "String" -> "the response text";
      default -> "the response body";
    };
  }

  private static String paramsSource(Op op) {
    String name = paramsClass(op);
    StringBuilder out = new StringBuilder();
    out.append("package ").append(PACKAGE).append(".params;\n\n");
    if (op.query().stream().anyMatch(q -> q.kind().equals("array"))) {
      out.append("import java.util.List;\n\n");
    }
    out.append("/** Query parameters of {@code ").append(op.id()).append("}. */\n");
    out.append(GENERATED).append("\npublic final class ").append(name);
    out.append(" extends QueryParams<").append(name).append("> {\n");
    out.append("  /** Creates an empty parameter set. */\n");
    out.append("  public ").append(name).append("() {}\n");
    for (Query q : op.query()) {
      String type =
          switch (q.kind()) {
            case "integer" -> "long";
            case "boolean" -> "boolean";
            case "array" -> "List<String>";
            default -> "String";
          };
      String value =
          switch (q.kind()) {
            case "integer" -> "Long.toString(value)";
            case "boolean" -> "Boolean.toString(value)";
            case "array" -> "String.join(\",\", value)";
            default -> "value";
          };
      out.append("\n  /**\n   * Sets {@code ")
          .append(javadoc(q.name()))
          .append("}")
          .append(q.required() ? " (required)" : "")
          .append(".\n   *\n   * @param value the value\n   * @return these parameters\n   */\n");
      out.append("  public ")
          .append(name)
          .append(" ")
          .append(camel(q.name()))
          .append("(")
          .append(type)
          .append(" value) {\n");
      out.append("    return set(").append(literal(q.name())).append(", ").append(value);
      out.append(");\n  }\n");
    }
    out.append("\n  @Override\n  protected ").append(name).append(" self() {\n");
    out.append("    return this;\n  }\n}\n");
    return out.toString();
  }

  private static String paramsClass(Op op) {
    return Character.toUpperCase(op.id().charAt(0)) + op.id().substring(1) + "Params";
  }

  private static String constant(String id) {
    return id.replaceAll("([a-z0-9])([A-Z])", "$1_$2").toUpperCase(Locale.ROOT);
  }

  private static String camel(String name) {
    StringBuilder out = new StringBuilder();
    boolean upper = false;
    for (char c : name.toCharArray()) {
      if (c == '_' || c == '.' || c == '-') {
        upper = true;
      } else if (upper) {
        out.append(Character.toUpperCase(c));
        upper = false;
      } else {
        out.append(c);
      }
    }
    return out.toString();
  }

  private static String snake(String name) {
    return name.replaceAll("([a-z0-9])([A-Z])", "$1_$2").toLowerCase(Locale.ROOT);
  }

  private static String javadoc(String text) {
    return text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("@", "&#64;")
        .replace("*/", "*&#47;")
        .replace("{", "&#123;")
        .replace("}", "&#125;");
  }

  private static String literal(String text) {
    StringBuilder out = new StringBuilder("\"");
    for (char c : text.toCharArray()) {
      switch (c) {
        case '"' -> out.append("\\\"");
        case '\\' -> out.append("\\\\");
        case '\n' -> out.append("\\n");
        default -> out.append(c);
      }
    }
    return out.append('"').toString();
  }
}
