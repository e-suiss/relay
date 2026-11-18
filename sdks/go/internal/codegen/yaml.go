package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type loader struct {
	docs map[string]*yaml.Node
}

func newLoader() *loader {
	return &loader{docs: map[string]*yaml.Node{}}
}

func (l *loader) doc(path string) *yaml.Node {
	if d, ok := l.docs[path]; ok {
		return d
	}
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	var n yaml.Node
	if err := yaml.Unmarshal(data, &n); err != nil {
		panic(fmt.Sprintf("%s: %v", path, err))
	}
	root := &n
	if root.Kind == yaml.DocumentNode && len(root.Content) > 0 {
		root = root.Content[0]
	}
	l.docs[path] = root
	return root
}

func (l *loader) follow(file, ref string) (string, *yaml.Node) {
	target, ptr, _ := strings.Cut(ref, "#")
	f := file
	if target != "" {
		f = filepath.Clean(filepath.Join(filepath.Dir(file), target))
	}
	n := l.doc(f)
	for _, seg := range strings.Split(strings.TrimPrefix(ptr, "/"), "/") {
		if seg == "" {
			continue
		}
		seg = strings.ReplaceAll(strings.ReplaceAll(seg, "~1", "/"), "~0", "~")
		n = get(n, seg)
		if n == nil {
			panic(fmt.Sprintf("unresolved reference %s from %s", ref, file))
		}
	}
	return f, n
}

func (l *loader) deref(file string, n *yaml.Node) (string, *yaml.Node) {
	for i := 0; i < 32; i++ {
		ref := str(n, "$ref")
		if ref == "" {
			return file, n
		}
		file, n = l.follow(file, ref)
	}
	panic("reference chain too long in " + file)
}

func unalias(n *yaml.Node) *yaml.Node {
	for n != nil && n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	return n
}

func get(n *yaml.Node, key string) *yaml.Node {
	n = unalias(n)
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			return unalias(n.Content[i+1])
		}
	}
	return nil
}

func str(n *yaml.Node, key string) string {
	v := get(n, key)
	if v == nil || v.Kind != yaml.ScalarNode {
		return ""
	}
	return v.Value
}

type pair struct {
	key   string
	value *yaml.Node
}

func pairs(n *yaml.Node) []pair {
	n = unalias(n)
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	out := make([]pair, 0, len(n.Content)/2)
	for i := 0; i+1 < len(n.Content); i += 2 {
		out = append(out, pair{key: n.Content[i].Value, value: unalias(n.Content[i+1])})
	}
	return out
}

func items(n *yaml.Node) []*yaml.Node {
	n = unalias(n)
	if n == nil || n.Kind != yaml.SequenceNode {
		return nil
	}
	out := make([]*yaml.Node, 0, len(n.Content))
	for _, c := range n.Content {
		out = append(out, unalias(c))
	}
	return out
}
