package main

import (
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

type gt struct {
	expr     string
	kind     string
	ref      string
	nullable bool
}

var anyT = gt{expr: "any", kind: "any"}

func (t gt) typeExpr() string {
	if t.ref != "" {
		return t.ref
	}
	return t.expr
}

type field struct {
	goName   string
	jsonName string
	t        gt
	required bool
	pointer  bool
}

type typeDef struct {
	name     string
	doc      string
	isStruct bool
	fields   []field
	alias    gt
}

type prop struct {
	name string
	file string
	n    *yaml.Node
}

type objectShape struct {
	props    []prop
	required map[string]bool
	doc      string
}

func (s *objectShape) add(p prop) {
	for i := range s.props {
		if s.props[i].name == p.name {
			s.props[i] = p
			return
		}
	}
	s.props = append(s.props, p)
}

func (s *objectShape) merge(o objectShape) {
	for _, p := range o.props {
		s.add(p)
	}
	for k := range o.required {
		s.required[k] = true
	}
	if s.doc == "" {
		s.doc = o.doc
	}
}

type gen struct {
	l     *loader
	types map[string]*typeDef
	named map[string]string
	used  map[string]bool
}

func newGen(l *loader) *gen {
	return &gen{
		l:     l,
		types: map[string]*typeDef{},
		named: map[string]string{},
		used:  map[string]bool{},
	}
}

func (g *gen) reserve(name string) string {
	if !g.used[name] {
		g.used[name] = true
		return name
	}
	for i := 2; ; i++ {
		candidate := name + strconv.Itoa(i)
		if !g.used[candidate] {
			g.used[candidate] = true
			return candidate
		}
	}
}

func typeList(n *yaml.Node) ([]string, bool) {
	t := get(n, "type")
	if t == nil {
		return nil, false
	}
	var raw []string
	if t.Kind == yaml.ScalarNode {
		raw = []string{t.Value}
	} else {
		for _, v := range items(t) {
			raw = append(raw, v.Value)
		}
	}
	var out []string
	null := false
	for _, v := range raw {
		if v == "null" {
			null = true
		} else {
			out = append(out, v)
		}
	}
	return out, null
}

func isNull(n *yaml.Node) bool {
	ts, null := typeList(n)
	return null && len(ts) == 0 && str(n, "$ref") == ""
}

func scalarType(n *yaml.Node) string {
	switch n.Tag {
	case "!!int":
		return "integer"
	case "!!float":
		return "number"
	case "!!bool":
		return "boolean"
	default:
		return "string"
	}
}

func hasProperties(n *yaml.Node) bool {
	p := get(n, "properties")
	return p != nil && len(p.Content) > 0
}

func (g *gen) shape(file string, n *yaml.Node) (objectShape, bool) {
	file, n = g.l.deref(file, n)
	s := objectShape{required: map[string]bool{}, doc: str(n, "description")}
	all := get(n, "allOf")
	for _, m := range items(all) {
		ms, ok := g.shape(file, m)
		if !ok {
			return s, false
		}
		s.merge(ms)
	}
	ts, _ := typeList(n)
	isObject := len(ts) == 1 && ts[0] == "object"
	if all == nil && !hasProperties(n) && !isObject {
		return s, false
	}
	if !hasProperties(n) && (get(n, "oneOf") != nil || get(n, "anyOf") != nil) {
		return s, false
	}
	for _, p := range pairs(get(n, "properties")) {
		s.add(prop{name: p.key, file: file, n: p.value})
	}
	for _, r := range items(get(n, "required")) {
		s.required[r.Value] = true
	}
	return s, true
}

func (g *gen) structCandidate(file string, n *yaml.Node) (objectShape, bool) {
	if str(n, "$ref") != "" {
		return objectShape{}, false
	}
	if hasProperties(n) || get(n, "allOf") != nil {
		s, ok := g.shape(file, n)
		if ok && (len(s.props) > 0 || get(n, "allOf") != nil) {
			return s, true
		}
	}
	return objectShape{}, false
}

func (g *gen) structType(s objectShape, name string) gt {
	def := &typeDef{name: name, doc: s.doc, isStruct: true}
	g.types[name] = def
	usedFields := map[string]bool{}
	for _, p := range s.props {
		goName := pascal(p.name)
		for i := 2; usedFields[goName]; i++ {
			goName = pascal(p.name) + strconv.Itoa(i)
		}
		usedFields[goName] = true
		t := g.typeOf(p.file, p.n, name+pascal(p.name))
		def.fields = append(def.fields, field{
			goName:   goName,
			jsonName: p.name,
			t:        t,
			required: s.required[p.name],
		})
	}
	return gt{ref: name}
}

func componentName(file, ptr string) string {
	base := filepath.Base(file)
	if filepath.Base(filepath.Dir(file)) != "components" {
		return ""
	}
	if base != "schemas.yaml" && base != "problem.yaml" {
		return ""
	}
	segs := strings.Split(strings.TrimPrefix(ptr, "/"), "/")
	if len(segs) != 1 || segs[0] == "" {
		return ""
	}
	return segs[0]
}

func (g *gen) refType(file, ref, hint string) gt {
	target, ptr, _ := strings.Cut(ref, "#")
	f := file
	if target != "" {
		f = filepath.Clean(filepath.Join(filepath.Dir(file), target))
	}
	if strings.HasSuffix(f, ".json") {
		return anyT
	}
	name := componentName(f, ptr)
	tf, tn := g.l.follow(file, ref)
	if name == "" {
		return g.typeOf(tf, tn, hint)
	}
	key := f + "#" + ptr
	if goName, ok := g.named[key]; ok {
		return gt{ref: goName}
	}
	goName := g.reserve(pascal(name))
	g.named[key] = goName
	if s, ok := g.structCandidate(tf, tn); ok {
		_, null := typeList(tn)
		t := g.structType(s, goName)
		if null {
			g.types[goName].alias.nullable = true
		}
		return t
	}
	def := &typeDef{name: goName, doc: str(tn, "description")}
	g.types[goName] = def
	alias := g.typeOf(tf, tn, goName+"Value")
	if alias.ref == goName {
		alias = anyT
	}
	def.alias = alias
	return gt{ref: goName}
}

func (g *gen) typeOf(file string, n *yaml.Node, hint string) gt {
	if n == nil {
		return anyT
	}
	if ref := str(n, "$ref"); ref != "" {
		return g.refType(file, ref, hint)
	}
	ts, null := typeList(n)
	if s, ok := g.structCandidate(file, n); ok {
		t := g.structType(s, g.reserve(hint))
		t.nullable = null
		return t
	}
	alts := get(n, "oneOf")
	if alts == nil {
		alts = get(n, "anyOf")
	}
	if alts != nil {
		var rest []*yaml.Node
		for _, m := range items(alts) {
			if isNull(m) {
				null = true
			} else {
				rest = append(rest, m)
			}
		}
		if len(rest) == 1 {
			t := g.typeOf(file, rest[0], hint)
			t.nullable = t.nullable || null
			return t
		}
		return gt{expr: "any", kind: "any", nullable: null}
	}
	if all := items(get(n, "allOf")); len(all) == 1 {
		t := g.typeOf(file, all[0], hint)
		t.nullable = t.nullable || null
		return t
	}
	t := ""
	switch {
	case len(ts) == 1:
		t = ts[0]
	case len(ts) > 1:
		return gt{expr: "any", kind: "any", nullable: null}
	case get(n, "const") != nil:
		t = scalarType(get(n, "const"))
	case len(items(get(n, "enum"))) > 0:
		t = scalarType(items(get(n, "enum"))[0])
	case get(n, "items") != nil:
		t = "array"
	case get(n, "additionalProperties") != nil:
		t = "object"
	default:
		return gt{expr: "any", kind: "any", nullable: null}
	}
	var r gt
	switch t {
	case "string":
		r = gt{expr: "string", kind: "scalar"}
	case "integer":
		r = gt{expr: "int64", kind: "scalar"}
	case "number":
		r = gt{expr: "float64", kind: "scalar"}
	case "boolean":
		r = gt{expr: "bool", kind: "scalar"}
	case "array":
		e := g.typeOf(file, get(n, "items"), hint+"Item")
		r = gt{expr: "[]" + e.typeExpr(), kind: "slice"}
	case "object":
		ap := get(n, "additionalProperties")
		if ap != nil && ap.Kind == yaml.MappingNode && len(ap.Content) > 0 {
			v := g.typeOf(file, ap, hint+"Value")
			r = gt{expr: "map[string]" + v.typeExpr(), kind: "map"}
		} else {
			r = gt{expr: "map[string]any", kind: "map"}
		}
	default:
		r = anyT
	}
	r.nullable = r.nullable || null
	return r
}

func (g *gen) kindOf(t gt) string {
	for i := 0; i < 32 && t.ref != ""; i++ {
		d, ok := g.types[t.ref]
		if !ok {
			panic(fmt.Sprintf("unknown type %s", t.ref))
		}
		if d.isStruct {
			return "struct"
		}
		t = d.alias
	}
	return t.kind
}

func (g *gen) nullableOf(t gt) bool {
	for i := 0; i < 32; i++ {
		if t.nullable {
			return true
		}
		if t.ref == "" {
			return false
		}
		d := g.types[t.ref]
		if d.isStruct {
			return d.alias.nullable
		}
		t = d.alias
	}
	return false
}

func (g *gen) fieldType(t gt, required bool) (string, bool) {
	switch g.kindOf(t) {
	case "slice", "map", "any":
		return t.typeExpr(), false
	}
	if required && !g.nullableOf(t) {
		return t.typeExpr(), false
	}
	return "*" + t.typeExpr(), true
}

func (g *gen) breakCycles() {
	for _, d := range g.types {
		for i := range d.fields {
			f := &d.fields[i]
			_, f.pointer = g.fieldType(f.t, f.required)
		}
	}
	state := map[string]int{}
	var visit func(name string)
	visit = func(name string) {
		state[name] = 1
		d := g.types[name]
		for i := range d.fields {
			f := &d.fields[i]
			if f.pointer || g.kindOf(f.t) != "struct" {
				continue
			}
			target := g.structTarget(f.t)
			switch state[target] {
			case 1:
				f.pointer = true
			case 0:
				visit(target)
			}
		}
		state[name] = 2
	}
	for _, name := range g.sortedTypes() {
		if g.types[name].isStruct && state[name] == 0 {
			visit(name)
		}
	}
}

func (g *gen) structTarget(t gt) string {
	for t.ref != "" {
		d := g.types[t.ref]
		if d.isStruct {
			return d.name
		}
		t = d.alias
	}
	return ""
}
