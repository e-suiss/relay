"""Rewrites the bundled subscriber contract into the subset both mobile generators read.

A property written as oneOf with a null branch becomes the non-null branch and leaves the
required list, so the generated field is optional and a JSON null decodes as absent. A oneOf
whose branches are all strings becomes one string. A property typed only as null becomes an
optional string.
"""

import json
import sys


def resolve(doc, schema):
    seen = 0
    while isinstance(schema, dict) and "$ref" in schema and seen < 32:
        ref = schema["$ref"]
        if not ref.startswith("#/"):
            return schema
        node = doc
        for part in ref[2:].split("/"):
            node = node[part.replace("~1", "/").replace("~0", "~")]
        schema = node
        seen += 1
    return schema


def is_null(schema):
    return isinstance(schema, dict) and schema.get("type") == "null"


def is_string(doc, schema):
    target = resolve(doc, schema)
    return (
        isinstance(target, dict)
        and target.get("type") == "string"
        and "oneOf" not in target
        and "anyOf" not in target
    )


def described(schema, source):
    if isinstance(source, dict) and "description" in source and "description" not in schema:
        schema = dict(schema)
        schema["description"] = source["description"]
    return schema


def simplify(doc, schema):
    if is_null(schema) and len(schema) <= 2:
        return described({"type": "string"}, schema), True
    if not isinstance(schema, dict) or not isinstance(schema.get("oneOf"), list):
        return schema, False
    branches = schema["oneOf"]
    rest = [branch for branch in branches if not is_null(branch)]
    nullable = len(rest) < len(branches)
    if len(rest) == 1 and nullable:
        return described(dict(rest[0]), schema), True
    if len(rest) > 1 and all(is_string(doc, branch) for branch in rest):
        return described({"type": "string"}, schema), nullable
    return schema, False


def walk(doc, node):
    if isinstance(node, list):
        for item in node:
            walk(doc, item)
        return
    if not isinstance(node, dict):
        return
    properties = node.get("properties")
    if isinstance(properties, dict):
        required = node.get("required")
        for name in list(properties):
            schema, nullable = simplify(doc, properties[name])
            properties[name] = schema
            if nullable and isinstance(required, list) and name in required:
                required.remove(name)
        if isinstance(required, list) and not required:
            del node["required"]
    for key in ("items", "schema", "additionalProperties"):
        if isinstance(node.get(key), dict):
            node[key], _ = simplify(doc, node[key])
    for value in node.values():
        walk(doc, value)


def main(source, target):
    with open(source, encoding="utf-8") as handle:
        doc = json.load(handle)
    walk(doc, doc)
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
