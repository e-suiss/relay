package relay

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	mathrand "math/rand/v2"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const maxResponseBytes = 32 << 20

// Client calls the Relay server API. Create it with NewClient; it is safe for concurrent use.
type Client struct {
	baseURL    string
	auth       Authorizer
	httpClient *http.Client
	maxRetries int
	timeout    time.Duration
	policy     retryPolicy
	userAgent  string
	now        func() time.Time
	sleep      func(context.Context, time.Duration) error
	random     func() float64
	newKey     func() string
}

// ClientOption configures a Client.
type ClientOption func(*Client)

// WithHTTPClient sets the HTTP client used for every request.
func WithHTTPClient(h *http.Client) ClientOption {
	return func(c *Client) { c.httpClient = h }
}

// WithMaxRetries sets how many times a retryable problem or a request without an answer is retried (default 3, 0 disables retries).
func WithMaxRetries(n int) ClientOption {
	return func(c *Client) {
		if n >= 0 {
			c.maxRetries = n
		}
	}
}

// WithTimeout sets the timeout of each attempt (default 30 seconds, 0 disables it).
func WithTimeout(d time.Duration) ClientOption {
	return func(c *Client) { c.timeout = d }
}

// NewClient returns a client for the Relay region at baseURL that authorizes requests with auth.
func NewClient(baseURL string, auth Authorizer, opts ...ClientOption) (*Client, error) {
	u, err := url.Parse(baseURL)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return nil, fmt.Errorf("relay: base URL must be an absolute http(s) URL: %q", baseURL)
	}
	base := strings.TrimRight(baseURL, "/")
	c := &Client{
		baseURL:    base,
		auth:       auth,
		httpClient: http.DefaultClient,
		maxRetries: 3,
		timeout:    30 * time.Second,
		policy:     defaultRetryPolicy,
		userAgent:  "esuiss-relay-go/" + Version,
		now:        time.Now,
		sleep:      sleepContext,
		random:     mathrand.Float64,
		newKey:     newUUID,
	}
	for _, opt := range opts {
		opt(c)
	}
	if s, ok := auth.(interface{ setRelayURL(string) }); ok {
		s.setRelayURL(base)
	}
	return c, nil
}

// Response is the raw answer of one request; Replayed is true when Relay answered a repeated Idempotency-Key with the first response.
type Response struct {
	StatusCode int
	Header     http.Header
	Body       []byte
	Replayed   bool
}

// RequestOption configures one call.
type RequestOption func(*callOptions)

type callOptions struct {
	idempotencyKey string
	timeout        time.Duration
	header         http.Header
	maxRetries     int
	capture        **Response
}

// WithIdempotencyKey sets the Idempotency-Key of a mutating call instead of a generated one.
func WithIdempotencyKey(key string) RequestOption {
	return func(o *callOptions) { o.idempotencyKey = key }
}

// WithRequestTimeout sets the timeout of each attempt of this call.
func WithRequestTimeout(d time.Duration) RequestOption {
	return func(o *callOptions) { o.timeout = d }
}

// WithHeader adds a header to this call; the SDK's own headers cannot be replaced.
func WithHeader(name, value string) RequestOption {
	return func(o *callOptions) {
		if o.header == nil {
			o.header = http.Header{}
		}
		o.header.Add(name, value)
	}
}

// WithRetries sets how many times a retryable problem of this call is retried.
func WithRetries(n int) RequestOption {
	return func(o *callOptions) {
		if n >= 0 {
			o.maxRetries = n
		}
	}
}

// WithResponse stores the last raw response of this call in dst, for headers such as Idempotency-Replayed.
func WithResponse(dst **Response) RequestOption {
	return func(o *callOptions) { o.capture = dst }
}

// Do sends a request to any path of the API and decodes a JSON answer into out when out is not nil; POST, PUT, PATCH and DELETE carry an Idempotency-Key.
func (c *Client) Do(ctx context.Context, method, path string, body, out any, opts ...RequestOption) error {
	method = strings.ToUpper(method)
	mutating := method == http.MethodPost || method == http.MethodPut ||
		method == http.MethodPatch || method == http.MethodDelete
	r := newRequest(method, path, mutating)
	if body != nil {
		r.setBody(body, "application/json")
	}
	resp, err := c.send(ctx, r, opts)
	if err != nil {
		return err
	}
	if out != nil {
		return decodeJSON(resp, out)
	}
	return nil
}

// X-29
// API-10
// API-65
func (c *Client) send(ctx context.Context, r *request, opts []RequestOption) (*Response, error) {
	o := callOptions{timeout: c.timeout, maxRetries: c.maxRetries}
	for _, opt := range opts {
		opt(&o)
	}
	var payload []byte
	if r.hasBody {
		data, err := json.Marshal(r.body)
		if err != nil {
			return nil, fmt.Errorf("relay: encode request: %w", err)
		}
		payload = data
	}
	key := ""
	if r.idempotent {
		key = o.idempotencyKey
		if key == "" {
			key = c.newKey()
		}
	}
	renewed := false
	for retry := 1; ; retry++ {
		var failure error
		var retryAfter *time.Duration
		retryable := false
		resp, err := c.attempt(ctx, r, payload, key, o)
		if err != nil {
			var connErr *ConnectionError
			if !errors.As(err, &connErr) || ctx.Err() != nil {
				return nil, err
			}
			failure, retryable = err, true
		} else {
			if o.capture != nil {
				*o.capture = resp
			}
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				return resp, nil
			}
			apiErr := parseAPIError(resp, c.now())
			if resp.StatusCode == http.StatusUnauthorized && apiErr.Code == "auth_expired_token" &&
				!renewed && c.auth != nil {
				c.auth.Invalidate()
				renewed = true
				retry--
				continue
			}
			failure, retryable, retryAfter = classify(apiErr), apiErr.Retryable, apiErr.RetryAfter
		}
		delay, reason := c.policy.decide(retry, o.maxRetries, retryable, retryAfter, c.random())
		if reason != "" {
			return nil, failure
		}
		if err := c.sleep(ctx, delay); err != nil {
			return nil, &ConnectionError{Err: err}
		}
	}
}

func (c *Client) attempt(ctx context.Context, r *request, payload []byte, key string, o callOptions) (*Response, error) {
	if o.timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, o.timeout)
		defer cancel()
	}
	target := c.baseURL + r.path
	if len(r.query) > 0 {
		target += "?" + r.query.Encode()
	}
	var body io.Reader
	if payload != nil {
		body = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(ctx, r.method, target, body)
	if err != nil {
		return nil, fmt.Errorf("relay: build request: %w", err)
	}
	h := req.Header
	for k, v := range o.header {
		h[k] = append([]string(nil), v...)
	}
	for k, v := range r.header {
		h[k] = append([]string(nil), v...)
	}
	h.Set("Accept", "application/json")
	h.Set("User-Agent", c.userAgent)
	h.Set("Relay-Version", APIVersion)
	if payload != nil {
		h.Set("Content-Type", r.contentType)
	}
	if key != "" {
		h.Set("Idempotency-Key", key)
	}
	if c.auth != nil {
		ah, err := c.auth.Authorize(ctx, r.method, target)
		if err != nil {
			return nil, err
		}
		for k, v := range ah {
			h[k] = v
		}
	}
	res, err := c.httpClient.Do(req)
	if err != nil {
		return nil, &ConnectionError{Err: err}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, maxResponseBytes))
	if err != nil {
		return nil, &ConnectionError{Err: err}
	}
	return &Response{
		StatusCode: res.StatusCode,
		Header:     res.Header,
		Body:       data,
		Replayed:   strings.EqualFold(res.Header.Get("Idempotency-Replayed"), "true"),
	}, nil
}

func sleepContext(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(errors.New("relay: no randomness for an idempotency key"))
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}
