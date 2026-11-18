package relay

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

type request struct {
	method      string
	path        string
	query       url.Values
	header      http.Header
	body        any
	hasBody     bool
	contentType string
	idempotent  bool
}

func newRequest(method, path string, idempotent bool) *request {
	return &request{
		method:     method,
		path:       path,
		query:      url.Values{},
		header:     http.Header{},
		idempotent: idempotent,
	}
}

func (r *request) clone() *request {
	c := *r
	c.query = url.Values{}
	for k, v := range r.query {
		c.query[k] = append([]string(nil), v...)
	}
	c.header = r.header.Clone()
	return &c
}

func (r *request) addQuery(name, value string) {
	r.query.Add(name, value)
}

func (r *request) setHeader(name, value string) {
	if value != "" {
		r.header.Set(name, value)
	}
}

func (r *request) setBody(body any, contentType string) {
	r.body = body
	r.hasBody = true
	r.contentType = contentType
}

func addQueryList[T any](r *request, name string, values []T, explode bool) {
	if len(values) == 0 {
		return
	}
	if explode {
		for _, v := range values {
			r.query.Add(name, formatValue(v))
		}
		return
	}
	r.query.Set(name, joinValues(values))
}

func joinValues[T any](values []T) string {
	parts := make([]string, 0, len(values))
	for _, v := range values {
		parts = append(parts, formatValue(v))
	}
	return strings.Join(parts, ",")
}

func formatValue(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case int64:
		return strconv.FormatInt(x, 10)
	case int:
		return strconv.Itoa(x)
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(x)
	case fmt.Stringer:
		return x.String()
	default:
		data, err := json.Marshal(x)
		if err != nil {
			return fmt.Sprint(x)
		}
		return strings.Trim(string(data), "\"")
	}
}

func pathSegment(v any) string {
	return url.PathEscape(formatValue(v))
}

func decodeJSON(resp *Response, out any) error {
	if len(resp.Body) == 0 {
		return nil
	}
	if err := json.Unmarshal(resp.Body, out); err != nil {
		return fmt.Errorf("relay: decode response: %w", err)
	}
	return nil
}
