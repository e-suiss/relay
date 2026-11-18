package main

import (
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

var hiddenHeaders = map[string]bool{
	"relay-version":     true,
	"relay-beta":        true,
	"idempotency-key":   true,
	"dpop":              true,
	"authorization":     true,
	"relay-tenant":      true,
	"relay-environment": true,
	"relay-csrf-token":  true,
}

var skippedTags = map[string]bool{
	"access":            true,
	"messaging-inbound": true,
}

var methods = []string{"get", "put", "post", "delete", "patch"}

type param struct {
	name     string
	in       string
	goName   string
	required bool
	explode  bool
	t        gt
}

type operation struct {
	id         string
	goName     string
	method     string
	path       string
	summary    string
	paramsName string
	pathParams []param
	params     []param
	idempotent bool
	hasBody    bool
	bodyType   string
	bodyCT     string
	resKind    string
	resType    string
	itemType   string
}

func (g *gen) operations(file string, root *yaml.Node) []operation {
	var out []operation
	globalSec := get(root, "security")
	for _, p := range pairs(get(root, "paths")) {
		if strings.HasPrefix(p.key, "/inbound/") {
			continue
		}
		pathItem := p.value
		shared := items(get(pathItem, "parameters"))
		for _, m := range methods {
			opNode := get(pathItem, m)
			if opNode == nil {
				continue
			}
			if tags := items(get(opNode, "tags")); len(tags) > 0 && skippedTags[tags[0].Value] {
				continue
			}
			sec := get(opNode, "security")
			if sec == nil {
				sec = globalSec
			}
			if !selected(sec) {
				continue
			}
			op, ok := g.operation(file, p.key, m, opNode, shared)
			if ok {
				out = append(out, op)
			}
		}
	}
	return out
}

func selected(sec *yaml.Node) bool {
	reqs := items(sec)
	if len(reqs) == 0 {
		return true
	}
	for _, r := range reqs {
		if get(r, "access_bearer") != nil {
			return true
		}
	}
	return false
}

func (g *gen) operation(file, path, method string, n *yaml.Node, shared []*yaml.Node) (operation, bool) {
	id := str(n, "operationId")
	op := operation{
		id:      id,
		goName:  pascal(id),
		method:  strings.ToUpper(method),
		path:    path,
		summary: firstSentence(str(n, "summary")),
	}
	all := append(append([]*yaml.Node{}, shared...), items(get(n, "parameters"))...)
	usedFields := map[string]bool{}
	usedArgs := map[string]bool{}
	hasStartingAfter := false
	for _, raw := range all {
		pf, pn := g.l.deref(file, raw)
		name := str(pn, "name")
		in := str(pn, "in")
		if in == "header" && hiddenHeaders[strings.ToLower(name)] {
			if strings.EqualFold(name, "idempotency-key") {
				op.idempotent = true
			}
			continue
		}
		if in == "cookie" {
			continue
		}
		explode := true
		if e := get(pn, "explode"); e != nil && e.Value == "false" {
			explode = false
		}
		prm := param{
			name:     name,
			in:       in,
			required: str(pn, "required") == "true",
			explode:  explode,
			t:        g.typeOf(pf, get(pn, "schema"), op.goName+pascal(name)),
		}
		if in == "path" {
			prm.goName = lowerCamel(name)
			for i := 2; usedArgs[prm.goName]; i++ {
				prm.goName = lowerCamel(name) + strconv.Itoa(i)
			}
			usedArgs[prm.goName] = true
			op.pathParams = append(op.pathParams, prm)
			continue
		}
		if in == "query" && name == "starting_after" {
			hasStartingAfter = true
		}
		prm.goName = pascal(name)
		for i := 2; usedFields[prm.goName]; i++ {
			prm.goName = pascal(name) + strconv.Itoa(i)
		}
		usedFields[prm.goName] = true
		op.params = append(op.params, prm)
	}
	ordered := make([]param, 0, len(op.pathParams))
	for _, seg := range strings.Split(path, "/") {
		if strings.HasPrefix(seg, "{") && strings.HasSuffix(seg, "}") {
			name := strings.TrimSuffix(strings.TrimPrefix(seg, "{"), "}")
			for _, pp := range op.pathParams {
				if pp.name == name {
					ordered = append(ordered, pp)
				}
			}
		}
	}
	op.pathParams = ordered
	if len(op.params) > 0 {
		op.paramsName = g.reserve(op.goName + "Params")
	}

	if rbRaw := get(n, "requestBody"); rbRaw != nil {
		rf, rb := g.l.deref(file, rbRaw)
		content := get(rb, "content")
		ct := ""
		for _, candidate := range []string{"application/json", "application/merge-patch+json"} {
			if get(content, candidate) != nil {
				ct = candidate
				break
			}
		}
		if ct == "" {
			return op, false
		}
		op.hasBody = true
		op.bodyCT = ct
		schema := get(get(content, ct), "schema")
		t := g.typeOf(rf, schema, op.goName+"Request")
		switch {
		case ct == "application/merge-patch+json":
			op.bodyType = "any"
		case g.kindOf(t) == "struct" || g.kindOf(t) == "scalar":
			op.bodyType = "*" + t.typeExpr()
		default:
			op.bodyType = t.typeExpr()
		}
	}

	op.resKind = "none"
	responses := pairs(get(n, "responses"))
	var codes []int
	byCode := map[int]*yaml.Node{}
	for _, r := range responses {
		code, err := strconv.Atoi(r.key)
		if err != nil || code < 200 || code > 299 {
			continue
		}
		codes = append(codes, code)
		byCode[code] = r.value
	}
	sort.Ints(codes)
	for _, code := range codes {
		rf, rn := g.l.deref(file, byCode[code])
		content := get(rn, "content")
		if content == nil {
			continue
		}
		if js := get(content, "application/json"); js != nil {
			schema := get(js, "schema")
			if hasStartingAfter {
				if item, ok := g.pageItem(rf, schema, op.goName+"Item"); ok {
					op.resKind = "page"
					op.itemType = item
					break
				}
			}
			t := g.typeOf(rf, schema, op.goName+"Response")
			switch g.kindOf(t) {
			case "any":
				op.resKind = "raw"
			case "struct":
				op.resKind = "struct"
				op.resType = t.typeExpr()
			default:
				op.resKind = "value"
				op.resType = t.typeExpr()
			}
			break
		}
		op.resKind = "text"
		break
	}
	return op, true
}

func (g *gen) pageItem(file string, schema *yaml.Node, hint string) (string, bool) {
	s, ok := g.shape(file, schema)
	if !ok {
		return "", false
	}
	var data *prop
	hasMore, next := false, false
	for i := range s.props {
		switch s.props[i].name {
		case "data":
			data = &s.props[i]
		case "has_more":
			hasMore = true
		case "next_cursor":
			next = true
		}
	}
	if data == nil || !hasMore || !next {
		return "", false
	}
	df, dn := g.l.deref(data.file, data.n)
	t := g.typeOf(df, get(dn, "items"), hint)
	return t.typeExpr(), true
}
