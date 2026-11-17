package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type vectorResponse struct {
	Status       int               `json:"status"`
	Headers      map[string]string `json:"headers"`
	Body         json.RawMessage   `json:"body"`
	NetworkError bool              `json:"network_error"`
}

func (v vectorResponse) bodyBytes() []byte {
	raw := strings.TrimSpace(string(v.Body))
	if raw == "" || raw == "null" {
		return nil
	}
	var text string
	if json.Unmarshal(v.Body, &text) == nil {
		return []byte(text)
	}
	return []byte(raw)
}

func (v vectorResponse) header() http.Header {
	h := http.Header{}
	for k, val := range v.Headers {
		h.Set(k, val)
	}
	return h
}

func (v vectorResponse) response() *Response {
	return &Response{StatusCode: v.Status, Header: v.header(), Body: v.bodyBytes()}
}

func (v vectorResponse) stub() stubResponse {
	h := v.header()
	if h.Get("Content-Type") == "" {
		h.Set("Content-Type", "application/octet-stream")
	}
	return stubResponse{status: v.Status, header: h, body: string(v.bodyBytes()), networkErr: v.NetworkError}
}

func loadSDKVector(t *testing.T, name string, out any) {
	t.Helper()
	path := filepath.Join("..", "..", "conformance", "sdk", "vectors", "1", name)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		t.Skipf("%s is not present", path)
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, out); err != nil {
		t.Fatal(err)
	}
}

func TestX29ConformanceErrors(t *testing.T) {
	var v struct {
		StatusDefaults []struct {
			Status    int     `json:"status"`
			Code      *string `json:"code"`
			Retryable bool    `json:"retryable"`
		} `json:"status_defaults"`
		Cases []struct {
			Name     string         `json:"name"`
			Response vectorResponse `json:"response"`
			Expect   struct {
				Class       string   `json:"class"`
				Code        *string  `json:"code"`
				Status      int      `json:"status"`
				Retryable   bool     `json:"retryable"`
				RequestID   *string  `json:"request_id"`
				RetryAfterS *float64 `json:"retry_after_s"`
				FieldErrors *int     `json:"field_errors"`
			} `json:"expect"`
		} `json:"cases"`
		Catalog []struct {
			Code      string `json:"code"`
			Family    string `json:"family"`
			Status    int    `json:"status"`
			Retryable bool   `json:"retryable"`
			Class     string `json:"class"`
		} `json:"catalog"`
	}
	loadSDKVector(t, "errors.json", &v)
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	for _, c := range v.Cases {
		apiErr := parseAPIError(c.Response.response(), now)
		err := classify(apiErr)
		e := c.Expect
		code := ""
		if e.Code != nil {
			code = *e.Code
		}
		if got := classOf(err); got != e.Class || apiErr.Code != code || apiErr.StatusCode != e.Status || apiErr.Retryable != e.Retryable {
			t.Errorf("%s: class %s code %q status %d retryable %t", c.Name, got, apiErr.Code, apiErr.StatusCode, apiErr.Retryable)
		}
		if e.RequestID != nil && apiErr.RequestID != *e.RequestID {
			t.Errorf("%s: request id %q", c.Name, apiErr.RequestID)
		}
		if e.RetryAfterS != nil && (apiErr.RetryAfter == nil || *apiErr.RetryAfter != time.Duration(*e.RetryAfterS*float64(time.Second))) {
			t.Errorf("%s: retry after %v", c.Name, apiErr.RetryAfter)
		}
		if e.FieldErrors != nil && len(apiErr.FieldErrors) != *e.FieldErrors {
			t.Errorf("%s: %d field errors", c.Name, len(apiErr.FieldErrors))
		}
	}
	for _, entry := range v.Catalog {
		spec, ok := errorCatalog[entry.Code]
		if !ok || spec.family != entry.Family || spec.status != entry.Status || spec.retryable != entry.Retryable {
			t.Errorf("catalog %s differs from the generated table", entry.Code)
		}
		if got := errorClass(entry.Code, entry.Status); got != entry.Class {
			t.Errorf("catalog %s: class %s, want %s", entry.Code, got, entry.Class)
		}
	}
	for _, d := range v.StatusDefaults {
		if d.Code != nil {
			continue
		}
		if got, ok := statusRetryable[d.Status]; !ok || got != d.Retryable {
			t.Errorf("status default %d differs", d.Status)
		}
	}
}

func TestX29ConformanceRetry(t *testing.T) {
	var v struct {
		Policy struct {
			MaxRetries     int `json:"max_retries"`
			BaseMS         int `json:"base_ms"`
			CapMS          int `json:"cap_ms"`
			MaxRetryAfterS int `json:"max_retry_after_s"`
		} `json:"policy"`
		Backoff []struct {
			Retry   int     `json:"retry"`
			Random  float64 `json:"random"`
			DelayMS int64   `json:"delay_ms"`
		} `json:"backoff"`
		Decisions []struct {
			Name         string         `json:"name"`
			Retry        int            `json:"retry"`
			Random       float64        `json:"random"`
			Now          time.Time      `json:"now"`
			NetworkError bool           `json:"network_error"`
			Response     vectorResponse `json:"response"`
			Expect       struct {
				Retry   bool   `json:"retry"`
				DelayMS int64  `json:"delay_ms"`
				Reason  string `json:"reason"`
			} `json:"expect"`
		} `json:"decisions"`
	}
	loadSDKVector(t, "retry.json", &v)
	p := defaultRetryPolicy
	if p.base != time.Duration(v.Policy.BaseMS)*time.Millisecond || p.maxDelay != time.Duration(v.Policy.CapMS)*time.Millisecond ||
		p.maxRetryAfter != time.Duration(v.Policy.MaxRetryAfterS)*time.Second {
		t.Fatalf("policy differs: %+v", v.Policy)
	}
	tc := newTestClient(t)
	if tc.maxRetries != v.Policy.MaxRetries {
		t.Fatalf("default max retries %d", tc.maxRetries)
	}
	for _, b := range v.Backoff {
		if got := p.backoff(b.Retry, b.Random); got != time.Duration(b.DelayMS)*time.Millisecond {
			t.Errorf("backoff retry %d random %v: %v", b.Retry, b.Random, got)
		}
	}
	for _, d := range v.Decisions {
		retryable := true
		var retryAfter *time.Duration
		if !d.NetworkError {
			apiErr := parseAPIError(d.Response.response(), d.Now)
			retryable, retryAfter = apiErr.Retryable, apiErr.RetryAfter
		}
		delay, reason := p.decide(d.Retry, v.Policy.MaxRetries, retryable, retryAfter, d.Random)
		if (reason == "") != d.Expect.Retry || reason != d.Expect.Reason {
			t.Errorf("%s: reason %q", d.Name, reason)
			continue
		}
		if d.Expect.Retry && delay != time.Duration(d.Expect.DelayMS)*time.Millisecond {
			t.Errorf("%s: delay %v, want %dms", d.Name, delay, d.Expect.DelayMS)
		}
	}
}

func TestX29ConformanceIdempotency(t *testing.T) {
	var v struct {
		KeyLength struct {
			Min int `json:"min"`
			Max int `json:"max"`
		} `json:"key_length"`
		Cases []struct {
			Name     string `json:"name"`
			Distinct bool   `json:"distinct_keys_across_calls"`
			Calls    []struct {
				Method    string           `json:"method"`
				Path      string           `json:"path"`
				TakesKey  bool             `json:"takes_idempotency_key"`
				CallerKey string           `json:"caller_idempotency"`
				Responses []vectorResponse `json:"responses"`
				Expect    struct {
					Requests  int    `json:"requests"`
					KeySent   bool   `json:"key_sent"`
					SameKey   bool   `json:"same_key_on_every_request"`
					SentKey   string `json:"sent_idempotency"`
					Outcome   string `json:"outcome"`
					Replayed  bool   `json:"replayed"`
					ErrClass  string `json:"error_class"`
					ErrorCode string `json:"error_code"`
				} `json:"expect"`
			} `json:"calls"`
		} `json:"cases"`
	}
	loadSDKVector(t, "idempotency.json", &v)
	for _, c := range v.Cases {
		tc := newTestClient(t)
		var firstKeys []string
		for i, call := range c.Calls {
			for _, r := range call.Responses {
				tc.transport.responses = append(tc.transport.responses, r.stub())
			}
			before := len(tc.transport.requests)
			var resp *Response
			opts := []RequestOption{WithResponse(&resp)}
			if call.CallerKey != "" {
				opts = append(opts, WithIdempotencyKey(call.CallerKey))
			}
			_, err := tc.send(context.Background(), newRequest(call.Method, call.Path, call.TakesKey), opts)
			reqs := tc.transport.requests[before:]
			e := call.Expect
			name := fmt.Sprintf("%s call %d", c.Name, i)
			if len(reqs) != e.Requests {
				t.Errorf("%s: %d requests", name, len(reqs))
				continue
			}
			key := reqs[0].Header.Get("Idempotency-Key")
			firstKeys = append(firstKeys, key)
			if (key != "") != e.KeySent {
				t.Errorf("%s: key %q", name, key)
			}
			if e.KeySent && (len(key) < v.KeyLength.Min || len(key) > v.KeyLength.Max) {
				t.Errorf("%s: key length %d", name, len(key))
			}
			for _, r := range reqs {
				if r.Header.Get("Idempotency-Key") != key {
					t.Errorf("%s: key changed across retries", name)
				}
			}
			if e.SentKey != "" && key != e.SentKey {
				t.Errorf("%s: sent %q", name, key)
			}
			switch e.Outcome {
			case "success":
				if err != nil || resp == nil || resp.Replayed != e.Replayed {
					t.Errorf("%s: err %v replayed %v", name, err, resp)
				}
			case "error":
				var apiErr *APIError
				if classOf(err) != e.ErrClass || !errors.As(err, &apiErr) || apiErr.Code != e.ErrorCode {
					t.Errorf("%s: got %v", name, err)
				}
			}
		}
		if c.Distinct {
			seen := map[string]bool{}
			for _, k := range firstKeys {
				if seen[k] {
					t.Errorf("%s: a key was reused by a new call", c.Name)
				}
				seen[k] = true
			}
		}
	}
}

type vectorItem struct {
	ID string `json:"id"`
}

func TestAPI56ConformancePagination(t *testing.T) {
	type params struct {
		Limit         *int64  `json:"limit"`
		StartingAfter *string `json:"starting_after"`
		EndingBefore  *string `json:"ending_before"`
	}
	var v struct {
		Cases []struct {
			Name      string `json:"name"`
			Params    params `json:"params"`
			Take      int    `json:"take"`
			Exchanges []struct {
				Query map[string]string `json:"query"`
				Page  json.RawMessage   `json:"page"`
			} `json:"exchanges"`
			Expect struct {
				Items    []string `json:"items"`
				Requests int      `json:"requests"`
			} `json:"expect"`
		} `json:"cases"`
		Rejections []struct {
			Name   string `json:"name"`
			Params params `json:"params"`
			Expect struct {
				Requests int    `json:"requests"`
				Error    string `json:"error"`
			} `json:"expect"`
		} `json:"rejections"`
	}
	loadSDKVector(t, "pagination.json", &v)
	build := func(p params) *request {
		r := newRequest("GET", "/v1/notifications", false)
		if p.Limit != nil {
			r.addQuery("limit", strconv.FormatInt(*p.Limit, 10))
		}
		if p.StartingAfter != nil {
			r.addQuery("starting_after", *p.StartingAfter)
		}
		if p.EndingBefore != nil {
			r.addQuery("ending_before", *p.EndingBefore)
		}
		return r
	}
	for _, c := range v.Cases {
		tc := newTestClient(t)
		for _, ex := range c.Exchanges {
			tc.transport.responses = append(tc.transport.responses, stubResponse{status: 200, body: string(ex.Page)})
		}
		r := build(c.Params)
		items := []string{}
		for it, err := range pageIter(context.Background(), func() (*Page[vectorItem], error) {
			return fetchPage[vectorItem](context.Background(), tc.Client, r, nil)
		}) {
			if err != nil {
				t.Fatalf("%s: %v", c.Name, err)
			}
			items = append(items, it.ID)
			if c.Take > 0 && len(items) == c.Take {
				break
			}
		}
		if fmt.Sprint(items) != fmt.Sprint(c.Expect.Items) || len(tc.transport.requests) != c.Expect.Requests {
			t.Errorf("%s: items %v after %d requests", c.Name, items, len(tc.transport.requests))
			continue
		}
		for i, ex := range c.Exchanges {
			got := tc.transport.requests[i].URL.Query()
			want := map[string]string{}
			for k := range got {
				want[k] = ""
			}
			for k, val := range ex.Query {
				want[k] = val
			}
			for k, val := range want {
				if got.Get(k) != val || len(got[k]) != 1 {
					t.Errorf("%s exchange %d: query %v, want %v", c.Name, i, got, ex.Query)
					break
				}
			}
		}
	}
	for _, rj := range v.Rejections {
		tc := newTestClient(t)
		_, err := fetchPage[vectorItem](context.Background(), tc.Client, build(rj.Params), nil)
		if rj.Expect.Error == "both_cursors" && !errors.Is(err, ErrBothCursors) {
			t.Errorf("%s: got %v", rj.Name, err)
		}
		if len(tc.transport.requests) != rj.Expect.Requests {
			t.Errorf("%s: %d requests", rj.Name, len(tc.transport.requests))
		}
	}
}

func TestWH7ConformanceWebhookHeaders(t *testing.T) {
	var v struct {
		Cases []struct {
			Name    string             `json:"name"`
			Base    string             `json:"base"`
			Keys    []string           `json:"keys"`
			Now     *int64             `json:"now"`
			BodyHex *string            `json:"body_hex"`
			Headers map[string]*string `json:"headers"`
			Expect  struct {
				OK     bool   `json:"ok"`
				Scheme string `json:"scheme"`
				Error  string `json:"error"`
			} `json:"expect"`
		} `json:"cases"`
	}
	loadSDKVector(t, "webhooks.json", &v)
	sigs := loadSignatureVectors(t)
	keys := map[string]string{
		"ed25519_public_key": sigs.Keys.Ed25519PublicKey,
		"hmac_secret":        sigs.Keys.HMACSecret,
	}
	for _, c := range v.Cases {
		found := false
		for _, base := range sigs.Cases {
			if base.Name != c.Base {
				continue
			}
			found = true
			var given []string
			for _, k := range c.Keys {
				given = append(given, keys[k])
			}
			verifier, err := NewWebhookVerifier(given...)
			if err != nil {
				t.Fatal(err)
			}
			values := map[string]string{
				"webhook-id":        base.WebhookID,
				"webhook-timestamp": strconv.FormatInt(base.WebhookTimestamp, 10),
			}
			for name, val := range c.Headers {
				if val == nil {
					delete(values, name)
					continue
				}
				values[name] = strings.NewReplacer("{v1a}", base.V1a, "{v1}", base.V1).Replace(*val)
			}
			h := http.Header{}
			for name, val := range values {
				h[name] = []string{val}
			}
			body := mustHex(t, base.BodyHex)
			if c.BodyHex != nil {
				body = mustHex(t, *c.BodyHex)
			}
			now := time.Unix(base.WebhookTimestamp, 0)
			if c.Now != nil {
				now = time.Unix(*c.Now, 0)
			}
			scheme, err := verifier.VerifyAt(body, h, now)
			if c.Expect.OK {
				if err != nil || scheme != c.Expect.Scheme {
					t.Errorf("%s: scheme %q err %v", c.Name, scheme, err)
				}
				continue
			}
			var verr *WebhookVerificationError
			if !errors.As(err, &verr) || verr.Reason != c.Expect.Error {
				t.Errorf("%s: got %v, want %s", c.Name, err, c.Expect.Error)
			}
		}
		if !found {
			t.Fatalf("%s: unknown base %s", c.Name, c.Base)
		}
	}
}
