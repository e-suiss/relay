import 'dart:io';

import 'package:yaml/yaml.dart';

const String contractsDir = '../../contracts';
const String outDir = 'lib/src/generated';

const List<String> subscriberRoots = <String>[
  'DeviceStatusWrite',
  'DeviceStatus',
  'DeviceStatusList',
  'PushReceipt',
  'PushReceiptRecorded',
  'RealtimePoll',
  'RealtimeEnvelope',
  'InboxItemState',
  'InboxItem',
  'InboxCounters',
  'InboxItemList',
  'InboxChange',
  'InboxChanges',
  'InboxIntent',
  'InboxIntentResult',
  'InboxReadAll',
  'InboxReadAllResult',
  'InboxReconciliation',
  'PushContent',
  'WaitpointResponseRequest',
  'WaitpointResponseReceipt',
];

const List<String> componentRoots = <String>[
  'DeviceRegistration',
  'Device',
  'SubscriberPreferences',
  'MyPreferencesPatch',
  'ConsentList',
];

const List<String> operations = <String>[
  'getMyPreferences',
  'updateMyPreferences',
  'listMyConsents',
  'getMyPushContent',
  'registerMyDevice',
  'deleteMyDevice',
  'getMyDeviceStatus',
  'updateMyDeviceStatus',
  'recordMyPushReceipt',
  'streamRealtimeEvents',
  'pollRealtimeEvents',
  'listMyInboxItems',
  'getMyInboxItem',
  'applyMyInboxIntent',
  'respondToMyWaitpoint',
  'getMyInboxCounters',
  'listMyInboxChanges',
  'markAllMyInboxRead',
  'reportMyInboxInconsistency',
];

const Set<String> keywords = <String>{
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
};

const Set<String> enumReserved = <String>{'values', 'index', 'name'};

String normalize(String path) => Uri.file(path).normalizePath().toFilePath();

enum Kind {
  string,
  integer,
  number,
  boolean,
  any,
  map,
  stringMap,
  enumT,
  classT,
  list,
}

class DartType {
  DartType(this.kind, {this.name, this.item, this.nullable = false});

  final Kind kind;
  final String? name;
  final DartType? item;
  final bool nullable;

  DartType asNullable() =>
      DartType(kind, name: name, item: item, nullable: true);

  String get base {
    switch (kind) {
      case Kind.string:
        return 'String';
      case Kind.integer:
        return 'int';
      case Kind.number:
        return 'num';
      case Kind.boolean:
        return 'bool';
      case Kind.any:
        return 'Object?';
      case Kind.map:
        return 'Map<String, Object?>';
      case Kind.stringMap:
        return 'Map<String, String>';
      case Kind.enumT:
      case Kind.classT:
        return name!;
      case Kind.list:
        return 'List<${item!.base}>';
    }
  }

  String get declared {
    if (kind == Kind.any) return 'Object?';
    return nullable ? '$base?' : base;
  }

  bool get identity =>
      kind != Kind.enumT &&
      kind != Kind.classT &&
      !(kind == Kind.list && !item!.identity);
}

class Doc {
  Doc(this.file, this.root);

  final String file;
  final Map<String, Object?> root;
}

class Node {
  Node(this.doc, this.value);

  final Doc doc;
  final Map<String, Object?> value;
}

final Map<String, Doc> docs = <String, Doc>{};
final Map<String, Node> classes = <String, Node>{};
final Map<String, Node> enums = <String, Node>{};
final List<String> classOrder = <String>[];
final List<String> enumOrder = <String>[];

Object? plain(Object? value) {
  if (value is YamlMap) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> e in value.entries)
        e.key.toString(): plain(e.value),
    };
  }
  if (value is YamlList) {
    return <Object?>[for (final Object? e in value) plain(e)];
  }
  return value;
}

Doc load(String path) {
  final String file = normalize(File(path).absolute.path);
  return docs.putIfAbsent(file, () {
    final Object? root = plain(loadYaml(File(file).readAsStringSync()));
    return Doc(file, root! as Map<String, Object?>);
  });
}

Node deref(Doc doc, String ref, void Function(String name) named) {
  final int hash = ref.indexOf('#');
  final String filePart = ref.substring(0, hash);
  final String pointer = ref.substring(hash + 1);
  Doc target = doc;
  if (filePart.isNotEmpty) {
    final String dir = File(doc.file).parent.path;
    target = load('$dir/$filePart');
  }
  final List<String> parts = pointer
      .split('/')
      .where((String p) => p.isNotEmpty)
      .toList();
  Object? cur = target.root;
  for (final String p in parts) {
    cur = (cur! as Map<String, Object?>)[p];
  }
  named(parts.last);
  return Node(target, cur! as Map<String, Object?>);
}

bool isObjectWithProperties(Map<String, Object?> s) =>
    s['properties'] is Map && (s['properties']! as Map).isNotEmpty;

bool isNamedEnum(Map<String, Object?> s) =>
    s['type'] == 'string' && s['enum'] is List;

String pascal(String s) => s
    .split(RegExp(r'[_\-\s.]+'))
    .where((String p) => p.isNotEmpty)
    .map((String p) => p[0].toUpperCase() + p.substring(1))
    .join();

String camel(String s, {bool enumValue = false}) {
  final String p = pascal(s);
  final String c = p[0].toLowerCase() + p.substring(1);
  final bool reserved =
      keywords.contains(c) || (enumValue && enumReserved.contains(c));
  return reserved ? '${c}Value' : c;
}

DartType resolve(Node node, String suggested) {
  final Map<String, Object?> s = node.value;
  if (s[r'$ref'] is String) {
    String name = suggested;
    final Node target = deref(node.doc, s[r'$ref']! as String, (String n) {
      name = n;
    });
    if (isObjectWithProperties(target.value)) {
      registerClass(name, target);
      return DartType(Kind.classT, name: name);
    }
    if (isNamedEnum(target.value)) {
      if (!enums.containsKey(name)) {
        enums[name] = target;
        enumOrder.add(name);
      }
      return DartType(Kind.enumT, name: name);
    }
    return resolve(target, name);
  }
  final Object? alts = s['oneOf'] ?? s['anyOf'];
  if (alts is List) {
    bool hasNull = false;
    final List<DartType> types = <DartType>[];
    for (final Object? a in alts) {
      final Map<String, Object?> m = a! as Map<String, Object?>;
      if (m['type'] == 'null') {
        hasNull = true;
      } else {
        types.add(resolve(Node(node.doc, m), suggested));
      }
    }
    final Set<String> bases = types.map((DartType t) => t.base).toSet();
    final DartType result;
    if (bases.length == 1) {
      result = types.first;
    } else if (types.every((DartType t) => t.kind == Kind.classT)) {
      result = DartType(Kind.map);
    } else {
      result = DartType(Kind.any);
    }
    return hasNull ? result.asNullable() : result;
  }
  if (s.containsKey('const')) return DartType(Kind.string);
  switch (s['type']) {
    case 'string':
      return DartType(Kind.string);
    case 'integer':
      return DartType(Kind.integer);
    case 'number':
      return DartType(Kind.number);
    case 'boolean':
      return DartType(Kind.boolean);
    case 'array':
      final DartType item = resolve(
        Node(node.doc, s['items']! as Map<String, Object?>),
        '${suggested}Item',
      );
      return DartType(Kind.list, item: item);
    case 'object':
      if (isObjectWithProperties(s)) {
        registerClass(suggested, node);
        return DartType(Kind.classT, name: suggested);
      }
      final Object? additional = s['additionalProperties'];
      if (additional is Map<String, Object?>) {
        final DartType value = resolve(Node(node.doc, additional), suggested);
        if (value.kind == Kind.string) return DartType(Kind.stringMap);
      }
      return DartType(Kind.map);
  }
  if (isObjectWithProperties(s)) {
    registerClass(suggested, node);
    return DartType(Kind.classT, name: suggested);
  }
  if (s['additionalProperties'] is Map<String, Object?>) {
    final DartType value = resolve(
      Node(node.doc, s['additionalProperties']! as Map<String, Object?>),
      suggested,
    );
    if (value.kind == Kind.string) return DartType(Kind.stringMap);
    return DartType(Kind.map);
  }
  return DartType(Kind.any);
}

void registerClass(String name, Node node) {
  if (classes.containsKey(name)) return;
  classes[name] = node;
  classOrder.add(name);
}

String decode(DartType t, String e, int depth) {
  switch (t.kind) {
    case Kind.string:
      return '$e as String';
    case Kind.integer:
      return '($e as num).toInt()';
    case Kind.number:
      return '$e as num';
    case Kind.boolean:
      return '$e as bool';
    case Kind.any:
      return e;
    case Kind.map:
      return '$e as Map<String, Object?>';
    case Kind.stringMap:
      return '($e as Map<String, Object?>).map((String k, Object? v) => MapEntry<String, String>(k, v as String))';
    case Kind.enumT:
      return '${t.name}.fromWire($e as String)';
    case Kind.classT:
      return '${t.name}.fromJson($e as Map<String, Object?>)';
    case Kind.list:
      final String v = 'e$depth';
      return '($e as List<Object?>).map((Object? $v) => ${decode(t.item!, v, depth + 1)}).toList()';
  }
}

String decodeField(DartType t, String key) {
  final String e = "json['$key']";
  if (t.kind == Kind.any) return e;
  if (!t.nullable) return decode(t, e, 0);
  return '$e == null ? null : ${decode(t, e, 0)}';
}

String encode(DartType t, String e, int depth) {
  switch (t.kind) {
    case Kind.enumT:
      return '$e.wire';
    case Kind.classT:
      return '$e.toJson()';
    case Kind.list:
      if (t.item!.identity) return e;
      final String v = 'e$depth';
      return '$e.map((${t.item!.base} $v) => ${encode(t.item!, v, depth + 1)}).toList()';
    case Kind.string:
    case Kind.integer:
    case Kind.number:
    case Kind.boolean:
    case Kind.any:
    case Kind.map:
    case Kind.stringMap:
      return e;
  }
}

String encodeNullable(DartType t, String e) {
  switch (t.kind) {
    case Kind.enumT:
      return '$e?.wire';
    case Kind.classT:
      return '$e?.toJson()';
    case Kind.list:
      if (t.item!.identity) return e;
      return '$e?.map((${t.item!.base} e0) => ${encode(t.item!, 'e0', 1)}).toList()';
    case Kind.string:
    case Kind.integer:
    case Kind.number:
    case Kind.boolean:
    case Kind.any:
    case Kind.map:
    case Kind.stringMap:
      return e;
  }
}

class Field {
  Field(this.key, this.name, this.type, this.required);

  final String key;
  final String name;
  final DartType type;
  final bool required;
}

void collect(Node node, Map<String, Node> props, Set<String> req) {
  final Map<String, Object?> s = node.value;
  if (s[r'$ref'] is String) {
    collect(deref(node.doc, s[r'$ref']! as String, (String _) {}), props, req);
    return;
  }
  for (final Object? part in (s['allOf'] as List<Object?>? ?? <Object?>[])) {
    collect(Node(node.doc, part! as Map<String, Object?>), props, req);
  }
  for (final Object? r in (s['required'] as List<Object?>? ?? <Object?>[])) {
    req.add(r! as String);
  }
  final Object? properties = s['properties'];
  if (properties is Map<String, Object?>) {
    for (final MapEntry<String, Object?> p in properties.entries) {
      props[p.key] = Node(
        node.doc,
        p.value as Map<String, Object?>? ?? <String, Object?>{},
      );
    }
  }
}

String emitClass(String name, Node node) {
  final Set<String> req = <String>{};
  final Map<String, Node> props = <String, Node>{};
  collect(node, props, req);
  final List<Field> fields = <Field>[];
  for (final MapEntry<String, Node> p in props.entries) {
    DartType t = resolve(p.value, '$name${pascal(p.key)}');
    final bool required = req.contains(p.key);
    if (!required) t = t.asNullable();
    fields.add(Field(p.key, camel(p.key), t, required));
  }
  final StringBuffer b = StringBuffer();
  b.writeln('class $name {');
  b.writeln('  const $name({');
  for (final Field f in fields) {
    b.writeln(
      f.required ? '    required this.${f.name},' : '    this.${f.name},',
    );
  }
  b.writeln('  });');
  b.writeln();
  b.writeln('  factory $name.fromJson(Map<String, Object?> json) => $name(');
  for (final Field f in fields) {
    b.writeln('        ${f.name}: ${decodeField(f.type, f.key)},');
  }
  b.writeln('      );');
  b.writeln();
  for (final Field f in fields) {
    b.writeln('  final ${f.type.declared} ${f.name};');
    b.writeln();
  }
  b.writeln('  Map<String, Object?> toJson() => <String, Object?>{');
  for (final Field f in fields) {
    if (f.required) {
      final String v = f.type.nullable
          ? encodeNullable(f.type, f.name)
          : encode(f.type, f.name, 0);
      b.writeln("        '${f.key}': $v,");
    } else {
      final String v = f.type.identity
          ? f.name
          : encode(f.type, '${f.name}!', 0);
      b.writeln("        if (${f.name} != null) '${f.key}': $v,");
    }
  }
  b.writeln('      };');
  b.writeln('}');
  return b.toString();
}

String emitEnum(String name, Node node) {
  final List<String> values = <String>[
    for (final Object? v in node.value['enum']! as List<Object?>) v! as String,
  ];
  final StringBuffer b = StringBuffer();
  b.writeln('enum $name {');
  for (final String v in values) {
    b.writeln("  ${camel(v, enumValue: true)}('$v'),");
  }
  b.writeln("  unrecognized('');");
  b.writeln();
  b.writeln('  const $name(this.wire);');
  b.writeln();
  b.writeln('  final String wire;');
  b.writeln();
  b.writeln('  static $name fromWire(String value) => $name.values');
  b.writeln(
    '      .firstWhere((e) => e.wire == value, orElse: () => $name.unrecognized);',
  );
  b.writeln('}');
  return b.toString();
}

String models() {
  final Doc subscriber = load(
    File('$contractsDir/openapi/subscriber.yaml').absolute.path,
  );
  final Doc components = load(
    File('$contractsDir/openapi/components/schemas.yaml').absolute.path,
  );
  final Map<String, Object?> subSchemas =
      ((subscriber.root['components']! as Map<String, Object?>)['schemas'])!
          as Map<String, Object?>;
  for (final String r in subscriberRoots) {
    registerClass(r, Node(subscriber, subSchemas[r]! as Map<String, Object?>));
  }
  for (final String r in componentRoots) {
    registerClass(
      r,
      Node(components, components.root[r]! as Map<String, Object?>),
    );
  }
  final List<String> out = <String>[];
  int i = 0;
  while (i < classOrder.length) {
    final String name = classOrder[i];
    out.add(emitClass(name, classes[name]!));
    i++;
  }
  final List<String> sortedClasses = <String>[...classOrder]..sort();
  final List<String> sortedEnums = <String>[...enumOrder]..sort();
  final Map<String, String> byName = <String, String>{
    for (int k = 0; k < classOrder.length; k++) classOrder[k]: out[k],
  };
  final StringBuffer b = StringBuffer();
  for (final String e in sortedEnums) {
    b.writeln(emitEnum(e, enums[e]!));
  }
  for (final String c in sortedClasses) {
    b.writeln(byName[c]);
  }
  return b.toString();
}

String operationsFile() {
  final Doc subscriber = load(
    File('$contractsDir/openapi/subscriber.yaml').absolute.path,
  );
  final Map<String, Object?> paths =
      subscriber.root['paths']! as Map<String, Object?>;
  final Map<String, String> lines = <String, String>{};
  for (final MapEntry<String, Object?> p in paths.entries) {
    final Map<String, Object?> item = p.value! as Map<String, Object?>;
    for (final MapEntry<String, Object?> op in item.entries) {
      final Map<String, Object?>? o = op.value is Map<String, Object?>
          ? op.value! as Map<String, Object?>
          : null;
      final String? id = o?['operationId'] as String?;
      if (id == null || !operations.contains(id)) continue;
      final bool idem = o!['x-relay-idempotency'] == 'required';
      final List<String> scopes = <String>[
        for (final Object? s
            in (o['x-relay-scopes'] as List<Object?>? ?? <Object?>[]))
          "'$s'",
      ];
      lines[id] =
          "  $id('${op.key.toUpperCase()}', '${p.key}', idempotencyRequired: $idem, scopes: <String>[${scopes.join(', ')}]),";
    }
  }
  final StringBuffer b = StringBuffer();
  b.writeln('enum RelayOperation {');
  for (final String id in operations) {
    b.writeln(lines[id]!);
  }
  b.writeln('  ;');
  b.writeln();
  b.writeln('  const RelayOperation(this.method, this.path,');
  b.writeln(
    '      {required this.idempotencyRequired, required this.scopes});',
  );
  b.writeln();
  b.writeln('  final String method;');
  b.writeln();
  b.writeln('  final String path;');
  b.writeln();
  b.writeln('  final bool idempotencyRequired;');
  b.writeln();
  b.writeln('  final List<String> scopes;');
  b.writeln('}');
  final String version =
      (subscriber.root['info']! as Map<String, Object?>)['version']! as String;
  b.writeln();
  b.writeln("const String relayApiVersion = '$version';");
  return b.toString();
}

String errorCatalog() {
  final Map<String, Object?> errors =
      plain(loadYaml(File('$contractsDir/errors.yaml').readAsStringSync()))!
          as Map<String, Object?>;
  final StringBuffer b = StringBuffer();
  b.writeln('class RelayErrorSpec {');
  b.writeln(
    '  const RelayErrorSpec(this.status, this.family, {required this.retryable});',
  );
  b.writeln();
  b.writeln('  final int status;');
  b.writeln();
  b.writeln('  final String family;');
  b.writeln();
  b.writeln('  final bool retryable;');
  b.writeln('}');
  b.writeln();
  b.writeln('class RelayRetryDefault {');
  b.writeln(
    '  const RelayRetryDefault(this.status, this.code, {required this.retryable});',
  );
  b.writeln();
  b.writeln('  final int status;');
  b.writeln();
  b.writeln('  final String? code;');
  b.writeln();
  b.writeln('  final bool retryable;');
  b.writeln('}');
  b.writeln();
  b.writeln(
    'const List<RelayRetryDefault> relayRetryDefaults = <RelayRetryDefault>[',
  );
  for (final Object? d in errors['retryable_defaults']! as List<Object?>) {
    final Map<String, Object?> m = d! as Map<String, Object?>;
    final Object? code = m['code'];
    final String c = code == null ? 'null' : "'$code'";
    b.writeln(
      '  RelayRetryDefault(${m['status']}, $c, retryable: ${m['retryable']}),',
    );
  }
  b.writeln('];');
  b.writeln();
  b.writeln(
    'const Map<String, RelayErrorSpec> relayErrorCatalog = <String, RelayErrorSpec>{',
  );
  final List<Map<String, Object?>> codes =
      <Map<String, Object?>>[
        for (final Object? c in errors['codes']! as List<Object?>)
          c! as Map<String, Object?>,
      ]..sort(
        (Map<String, Object?> a, Map<String, Object?> z) =>
            (a['code']! as String).compareTo(z['code']! as String),
      );
  for (final Map<String, Object?> m in codes) {
    b.writeln(
      "  '${m['code']}': RelayErrorSpec(${m['status']}, '${m['family']}', retryable: ${m['retryable']}),",
    );
  }
  b.writeln('};');
  return b.toString();
}

void main() {
  Directory(outDir).createSync(recursive: true);
  File('$outDir/models.dart').writeAsStringSync(models());
  File('$outDir/operations.dart').writeAsStringSync(operationsFile());
  File('$outDir/error_catalog.dart').writeAsStringSync(errorCatalog());
}
