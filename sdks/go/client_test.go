package relay

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"testing"
	"time"
)

type stubResponse struct {
	status int
	header http.Header
	body   string
}

type stubTransport struct {
	mu        sync.Mutex
	responses []stubResponse
	requests  []*http.Request
	bodies    []string
}

func (s *stubTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	body := ""
	if req.Body != nil {
		data, _ := io.ReadAll(req.Body)
		body = string(data)
	}
	s.requests = append(s.requests, req)
	s.bodies = append(s.bodies, body)
	if len(s.responses) == 0 {
		return nil, errors.New("no stubbed response left")
	}
	r := s.responses[0]
	s.responses = s.responses[1:]
	h := r.header
	if h == nil {
		h = http.Header{}
	}
	if h.Get("Content-Type") == "" {
		h.Set("Content-Type", "application/json")
	}
	return &http.Response{
		StatusCode: r.status,
		Header:     h,
		Body:       io.NopCloser(bytes.NewBufferString(r.body)),
		Request:    req,
	}, nil
}

type stubAuth struct {
	authorized  int
	invalidated int
}

func (a *stubAuth) Authorize(_ context.Context, method, target string) (http.Header, error) {
	a.authorized++
	h := http.Header{}
	h.Set("Authorization", "DPoP token")
	h.Set("DPoP", fmt.Sprintf("proof-%d", a.authorized))
	return h, nil
}

func (a *stubAuth) Invalidate() { a.invalidated++ }

type testClient struct {
	*Client
	transport *stubTransport
	auth      *stubAuth
	sleeps    []time.Duration
}

func newTestClient(t *testing.T, responses ...stubResponse) *testClient {
	t.Helper()
	tr := &stubTransport{responses: responses}
	auth := &stubAuth{}
	c, err := NewClient("https://relay.test/", auth, WithHTTPClient(&http.Client{Transport: tr}))
	if err != nil {
		t.Fatal(err)
	}
	tc := &testClient{Client: c, transport: tr, auth: auth}
	c.now = func() time.Time { return time.Unix(1_800_000_000, 0) }
	c.random = func() float64 { return 0.5 }
	c.sleep = func(_ context.Context, d time.Duration) error {
		tc.sleeps = append(tc.sleeps, d)
		return nil
	}
	return tc
}

func problem(status int, code string, retryable bool) stubResponse {
	return stubResponse{
		status: status,
		header: http.Header{"Content-Type": {"application/problem+json"}},
		body: fmt.Sprintf(`{"type":"https://relay.test/v1/errors/%s","title":"t","status":%d,"code":"%s","retryable":%t}`,
			code, status, code, retryable),
	}
}

func TestX29IdempotencyKeyKeptAcrossRetries(t *testing.T) {
	tc := newTestClient(t,
		problem(503, "service_unavailable", true),
		problem(409, "idempotency_key_in_progress", true),
		stubResponse{status: 202, body: `{"ok":true}`},
	)
	var out map[string]any
	if err := tc.Do(context.Background(), "POST", "/v1/events", map[string]any{"workflow": "welcome"}, &out); err != nil {
		t.Fatal(err)
	}
	if len(tc.transport.requests) != 3 {
		t.Fatalf("%d attempts", len(tc.transport.requests))
	}
	key := tc.transport.requests[0].Header.Get("Idempotency-Key")
	if len(key) < 8 {
		t.Fatalf("no idempotency key: %q", key)
	}
	proofs := map[string]bool{}
	for i, req := range tc.transport.requests {
		if got := req.Header.Get("Idempotency-Key"); got != key {
			t.Fatalf("attempt %d key %q, want %q", i, got, key)
		}
		if req.Header.Get("Relay-Version") != APIVersion {
			t.Fatalf("Relay-Version %q", req.Header.Get("Relay-Version"))
		}
		proofs[req.Header.Get("DPoP")] = true
		if tc.transport.bodies[i] != `{"workflow":"welcome"}` {
			t.Fatalf("body %q", tc.transport.bodies[i])
		}
	}
	if len(proofs) != 3 {
		t.Fatal("a DPoP proof was reused across attempts")
	}
}

func TestX29CallerIdempotencyKeyAndNoKeyOnGet(t *testing.T) {
	tc := newTestClient(t, stubResponse{status: 200, body: `{}`}, stubResponse{status: 200, body: `{}`})
	if err := tc.Do(context.Background(), "POST", "/v1/x", map[string]any{}, nil, WithIdempotencyKey("order-4821-shipped")); err != nil {
		t.Fatal(err)
	}
	if err := tc.Do(context.Background(), "GET", "/v1/x", nil, nil); err != nil {
		t.Fatal(err)
	}
	if got := tc.transport.requests[0].Header.Get("Idempotency-Key"); got != "order-4821-shipped" {
		t.Fatalf("key %q", got)
	}
	if got := tc.transport.requests[1].Header.Get("Idempotency-Key"); got != "" {
		t.Fatalf("GET carried a key %q", got)
	}
}

func TestX29OnlyRetryableProblemsAreRetried(t *testing.T) {
	tc := newTestClient(t, problem(500, "internal_error", false))
	err := tc.Do(context.Background(), "GET", "/v1/x", nil, nil)
	var serverErr *ServerError
	if !errors.As(err, &serverErr) {
		t.Fatalf("got %T %v", err, err)
	}
	if len(tc.transport.requests) != 1 || len(tc.sleeps) != 0 {
		t.Fatal("a problem with retryable false was retried")
	}
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Code != "internal_error" || apiErr.Retryable {
		t.Fatalf("api error %+v", apiErr)
	}
}

func TestX29RetryAfterHonoured(t *testing.T) {
	limited := problem(429, "rate_limited", true)
	limited.header.Set("Retry-After", "3")
	tc := newTestClient(t, limited, stubResponse{status: 200, body: `{}`})
	if err := tc.Do(context.Background(), "GET", "/v1/x", nil, nil); err != nil {
		t.Fatal(err)
	}
	if len(tc.sleeps) != 1 || tc.sleeps[0] != 3*time.Second {
		t.Fatalf("sleeps %v", tc.sleeps)
	}
}

func TestX29RetryAfterTooLongIsNotWaited(t *testing.T) {
	limited := problem(429, "rate_limited", true)
	limited.header.Set("Retry-After", "3600")
	tc := newTestClient(t, limited)
	err := tc.Do(context.Background(), "GET", "/v1/x", nil, nil)
	var rl *RateLimitError
	if !errors.As(err, &rl) || len(tc.sleeps) != 0 {
		t.Fatalf("got %v after sleeps %v", err, tc.sleeps)
	}
	if rl.RetryAfter == nil || *rl.RetryAfter != time.Hour {
		t.Fatalf("retry after %v", rl.RetryAfter)
	}
}

func TestX29RetriesStopAtMax(t *testing.T) {
	tc := newTestClient(t,
		problem(503, "service_unavailable", true),
		problem(503, "service_unavailable", true),
		problem(503, "service_unavailable", true),
		problem(503, "service_unavailable", true),
	)
	err := tc.Do(context.Background(), "GET", "/v1/x", nil, nil)
	var serverErr *ServerError
	if !errors.As(err, &serverErr) || len(tc.transport.requests) != 4 || len(tc.sleeps) != 3 {
		t.Fatalf("err %v, %d attempts, sleeps %v", err, len(tc.transport.requests), tc.sleeps)
	}
	if tc.sleeps[0] != 250*time.Millisecond || tc.sleeps[1] != 500*time.Millisecond || tc.sleeps[2] != time.Second {
		t.Fatalf("full jitter at 0.5 gives half the ceiling: %v", tc.sleeps)
	}
}

func TestX29FullJitterBounds(t *testing.T) {
	p := defaultRetryPolicy
	for retry := 0; retry < 10; retry++ {
		ceiling := p.base << retry
		if ceiling > p.maxDelay {
			ceiling = p.maxDelay
		}
		low, _ := p.delay(retry, nil, 0)
		high, _ := p.delay(retry, nil, 0.999999)
		if low != 0 || high >= ceiling || high < ceiling*99/100 {
			t.Fatalf("retry %d: [%v, %v] for ceiling %v", retry, low, high, ceiling)
		}
	}
	ra := 2 * time.Second
	if d, ok := p.delay(0, &ra, 0.9); !ok || d != ra {
		t.Fatalf("Retry-After above the jitter wins: %v", d)
	}
}

func TestX29ExpiredTokenRenewedOnce(t *testing.T) {
	tc := newTestClient(t,
		problem(401, "auth_expired_token", false),
		problem(401, "auth_expired_token", false),
	)
	err := tc.Do(context.Background(), "GET", "/v1/x", nil, nil)
	var authErr *AuthenticationError
	if !errors.As(err, &authErr) {
		t.Fatalf("got %v", err)
	}
	if tc.auth.invalidated != 1 || len(tc.transport.requests) != 2 {
		t.Fatalf("invalidated %d, attempts %d", tc.auth.invalidated, len(tc.transport.requests))
	}
}

func TestX29TransportErrorIsConnectionError(t *testing.T) {
	tc := newTestClient(t)
	err := tc.Do(context.Background(), "GET", "/v1/x", nil, nil)
	var connErr *ConnectionError
	if !errors.As(err, &connErr) || len(tc.transport.requests) != 1 {
		t.Fatalf("got %v", err)
	}
}

func TestX29ErrorHierarchyFollowsCatalog(t *testing.T) {
	for code, spec := range errorCatalog {
		err := classify(&APIError{StatusCode: spec.status, Code: code})
		var ok bool
		switch {
		case spec.family == "idempotency":
			var e *IdempotencyError
			ok = errors.As(err, &e)
		case spec.family == "auth":
			var e *AuthenticationError
			ok = errors.As(err, &e)
		case spec.family == "quota":
			var e *RateLimitError
			ok = errors.As(err, &e)
		case spec.status >= 500:
			var e *ServerError
			ok = errors.As(err, &e)
		case spec.status == 404:
			var e *NotFoundError
			ok = errors.As(err, &e)
		case spec.status == 409 || spec.status == 412 || spec.status == 428:
			var e *ConflictError
			ok = errors.As(err, &e)
		default:
			var e *ValidationError
			ok = errors.As(err, &e)
		}
		if !ok {
			t.Errorf("%s (%s, %d) classified as %T", code, spec.family, spec.status, err)
		}
		var apiErr *APIError
		if !errors.As(err, &apiErr) || apiErr.Code != code {
			t.Errorf("%s does not unwrap to its problem", code)
		}
	}
}

func TestAPI56PaginationIsLazy(t *testing.T) {
	tc := newTestClient(t,
		stubResponse{status: 200, body: `{"object":"list","data":[{"id":"a"},{"id":"b"}],"has_more":true,"next_cursor":"c1","previous_cursor":null}`},
		stubResponse{status: 200, body: `{"object":"list","data":[{"id":"c"}],"has_more":false,"next_cursor":null,"previous_cursor":"c0"}`},
	)
	type item struct {
		ID string `json:"id"`
	}
	r := newRequest("GET", "/v1/things", false)
	r.addQuery("limit", "2")
	r.addQuery("ending_before", "x")
	seq := pageIter(context.Background(), func() (*Page[item], error) {
		return fetchPage[item](context.Background(), tc.Client, r, nil)
	})
	if len(tc.transport.requests) != 0 {
		t.Fatal("a page was fetched before iteration")
	}
	var ids []string
	for it, err := range seq {
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, it.ID)
		if it.ID == "b" && len(tc.transport.requests) != 1 {
			t.Fatal("the next page was fetched before the current one was used up")
		}
	}
	if fmt.Sprint(ids) != "[a b c]" || len(tc.transport.requests) != 2 {
		t.Fatalf("ids %v after %d requests", ids, len(tc.transport.requests))
	}
	second := tc.transport.requests[1].URL.Query()
	if second.Get("starting_after") != "c1" || second.Get("limit") != "2" || second.Has("ending_before") {
		t.Fatalf("second page query %v", second)
	}
}

func TestAPI56PaginationStopsEarly(t *testing.T) {
	tc := newTestClient(t,
		stubResponse{status: 200, body: `{"object":"list","data":[1,2],"has_more":true,"next_cursor":"c1"}`},
	)
	seq := pageIter(context.Background(), func() (*Page[int], error) {
		return fetchPage[int](context.Background(), tc.Client, newRequest("GET", "/v1/n", false), nil)
	})
	for range seq {
		break
	}
	if len(tc.transport.requests) != 1 {
		t.Fatal("iteration continued after break")
	}
}

func TestAPI55HeadersOnEveryRequest(t *testing.T) {
	tc := newTestClient(t, stubResponse{status: 204})
	var resp *Response
	if err := tc.Do(context.Background(), "DELETE", "/v1/x/a%2Fb", nil, nil, WithResponse(&resp), WithHeader("Relay-Version", "1999-01-01")); err != nil {
		t.Fatal(err)
	}
	req := tc.transport.requests[0]
	if req.Header.Get("Relay-Version") != APIVersion || req.Header.Get("User-Agent") != "esuiss-relay-go/"+Version {
		t.Fatalf("headers %v", req.Header)
	}
	if req.Header.Get("Authorization") != "DPoP token" || resp == nil || resp.StatusCode != 204 {
		t.Fatalf("auth %q resp %v", req.Header.Get("Authorization"), resp)
	}
	if pathSegment("a/b c") != "a%2Fb%20c" {
		t.Fatalf("path segment %q", pathSegment("a/b c"))
	}
}

func TestX30MergeStreamAndHistoryDeduplicates(t *testing.T) {
	type rec struct {
		id  string
		seq int64
	}
	stream := make(chan rec, 4)
	stream <- rec{"b", 2}
	stream <- rec{"c", 3}
	stream <- rec{"b", 2}
	stream <- rec{"a", 4}
	close(stream)
	history := func(yield func(rec, error) bool) {
		for _, r := range []rec{{"a", 1}, {"b", 2}} {
			if !yield(r, nil) {
				return
			}
		}
	}
	var got []rec
	for r, err := range MergeStreamAndHistory(context.Background(), stream, history,
		func(r rec) string { return r.id }, func(r rec) int64 { return r.seq }) {
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, r)
	}
	want := []rec{{"a", 1}, {"b", 2}, {"c", 3}, {"a", 4}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestX30ISODuration(t *testing.T) {
	cases := map[string]time.Duration{"PT30S": 30 * time.Second, "PT1H30M": 90 * time.Minute, "P1D": 24 * time.Hour, "P1W": 7 * 24 * time.Hour}
	for in, want := range cases {
		if got, ok := parseISODuration(in); !ok || got != want {
			t.Errorf("%s: %v", in, got)
		}
	}
	if _, ok := parseISODuration("PT"); ok {
		t.Error("PT accepted")
	}
}

func TestX30AwaitWaitpointUntilResolved(t *testing.T) {
	open := `{"object":"waitpoint","id":"wp_1","state":"open","heartbeat_interval":"PT10S"}`
	tc := newTestClient(t,
		stubResponse{status: 200, body: open},
		stubResponse{status: 200, body: open},
		stubResponse{status: 200, body: open},
		stubResponse{status: 200, body: `{"object":"waitpoint","id":"wp_1","state":"resolved"}`},
	)
	wp, err := tc.AwaitWaitpoint(context.Background(), "wp_1", time.Minute, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if string(wp.State) != "resolved" {
		t.Fatalf("state %s", wp.State)
	}
	if tc.transport.requests[1].Method != "POST" || tc.transport.requests[1].URL.Path != "/v1/waitpoints/wp_1/heartbeat" {
		t.Fatalf("second request %s %s", tc.transport.requests[1].Method, tc.transport.requests[1].URL.Path)
	}
}

func TestX30AwaitWaitpointTimesOut(t *testing.T) {
	tc := newTestClient(t,
		stubResponse{status: 200, body: `{"object":"waitpoint","id":"wp_1","state":"open"}`},
	)
	_, err := tc.AwaitWaitpoint(context.Background(), "wp_1", 0, time.Second)
	var timeout *WaitTimeoutError
	if !errors.As(err, &timeout) || timeout.State != "open" {
		t.Fatalf("got %v", err)
	}
}
