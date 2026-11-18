package main

import (
	"strings"
	"unicode"
)

var initialisms = map[string]string{
	"api":   "API",
	"csrf":  "CSRF",
	"dns":   "DNS",
	"html":  "HTML",
	"http":  "HTTP",
	"https": "HTTPS",
	"id":    "ID",
	"ids":   "IDs",
	"ip":    "IP",
	"json":  "JSON",
	"jwks":  "JWKS",
	"jwt":   "JWT",
	"mcp":   "MCP",
	"otp":   "OTP",
	"sms":   "SMS",
	"tls":   "TLS",
	"ttl":   "TTL",
	"uri":   "URI",
	"url":   "URL",
	"urls":  "URLs",
	"uuid":  "UUID",
}

var keywords = map[string]bool{
	"break": true, "case": true, "chan": true, "const": true, "continue": true,
	"default": true, "defer": true, "else": true, "fallthrough": true, "for": true,
	"func": true, "go": true, "goto": true, "if": true, "import": true,
	"interface": true, "map": true, "package": true, "range": true, "return": true,
	"select": true, "struct": true, "switch": true, "type": true, "var": true,
	"ctx": true, "body": true, "params": true, "opts": true, "r": true,
	"resp": true, "err": true, "out": true, "c": true,
}

func words(s string) []string {
	var out []string
	var cur []rune
	runes := []rune(s)
	flush := func() {
		if len(cur) > 0 {
			out = append(out, string(cur))
			cur = nil
		}
	}
	for i, r := range runes {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			flush()
			continue
		}
		if unicode.IsUpper(r) && len(cur) > 0 {
			prev := runes[i-1]
			nextLower := i+1 < len(runes) && unicode.IsLower(runes[i+1])
			if unicode.IsLower(prev) || unicode.IsDigit(prev) || (unicode.IsUpper(prev) && nextLower) {
				flush()
			}
		}
		cur = append(cur, r)
	}
	flush()
	return out
}

func pascal(s string) string {
	var b strings.Builder
	for _, w := range words(s) {
		if up, ok := initialisms[strings.ToLower(w)]; ok {
			b.WriteString(up)
			continue
		}
		r := []rune(w)
		b.WriteRune(unicode.ToUpper(r[0]))
		b.WriteString(string(r[1:]))
	}
	out := b.String()
	if out == "" {
		return "Field"
	}
	if unicode.IsDigit([]rune(out)[0]) {
		return "N" + out
	}
	return out
}

func lowerCamel(s string) string {
	ws := words(s)
	if len(ws) == 0 {
		return "value"
	}
	var b strings.Builder
	b.WriteString(strings.ToLower(ws[0]))
	if len(ws) > 1 {
		b.WriteString(pascal(strings.Join(ws[1:], "_")))
	}
	out := b.String()
	if keywords[out] {
		out += "Value"
	}
	if unicode.IsDigit([]rune(out)[0]) {
		out = "n" + out
	}
	return out
}

func firstSentence(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if i := strings.Index(s, ". "); i >= 0 {
		s = s[:i+1]
	}
	r := []rune(s)
	if len(r) > 200 {
		cut := string(r[:200])
		if j := strings.LastIndex(cut, " "); j > 0 {
			cut = cut[:j]
		}
		s = cut + " ..."
	}
	return s
}
