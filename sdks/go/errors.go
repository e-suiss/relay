package relay

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type errorSpec struct {
	family    string
	status    int
	retryable bool
}

// APIError is an RFC 9457 problem answered by Relay. Every typed error wraps one, so errors.As with *APIError reaches the fields of any of them.
type APIError struct {
	StatusCode int
	Code       string
	Title      string
	Detail     string
	Type       string
	Instance   string
	RequestID  string
	Retryable  bool
	RetryAfter *time.Duration
	Problem    map[string]any
	Header     http.Header
}

func (e *APIError) Error() string {
	text := e.Detail
	if text == "" {
		text = e.Title
	}
	if e.Code == "" {
		return fmt.Sprintf("relay: HTTP %d: %s", e.StatusCode, text)
	}
	return fmt.Sprintf("relay: HTTP %d %s: %s", e.StatusCode, e.Code, text)
}

// AuthenticationError is a problem of the auth family: missing, invalid or expired credentials, scope, role or suspension.
type AuthenticationError struct{ *APIError }

// Unwrap returns the problem.
func (e *AuthenticationError) Unwrap() error { return e.APIError }

// ValidationError is a client error that no other type covers: a malformed request, a failed validation or an unknown field.
type ValidationError struct{ *APIError }

// Unwrap returns the problem.
func (e *ValidationError) Unwrap() error { return e.APIError }

// NotFoundError is a 404: the resource does not exist in this tenant and environment.
type NotFoundError struct{ *APIError }

// Unwrap returns the problem.
func (e *NotFoundError) Unwrap() error { return e.APIError }

// ConflictError is a resource conflict or a failed precondition (409, 412, 428).
type ConflictError struct{ *APIError }

// Unwrap returns the problem.
func (e *ConflictError) Unwrap() error { return e.APIError }

// RateLimitError is a problem of the quota family: a rate limit, an exhausted quota or a batch above its limit.
type RateLimitError struct{ *APIError }

// Unwrap returns the problem.
func (e *RateLimitError) Unwrap() error { return e.APIError }

// IdempotencyError is a problem of the idempotency family: a missing, invalid, reused or in-progress Idempotency-Key.
type IdempotencyError struct{ *APIError }

// Unwrap returns the problem.
func (e *IdempotencyError) Unwrap() error { return e.APIError }

// ServerError is a 5xx answer.
type ServerError struct{ *APIError }

// Unwrap returns the problem.
func (e *ServerError) Unwrap() error { return e.APIError }

// ConnectionError is a failure to reach Relay or Access, or to read the answer; it is not retried.
type ConnectionError struct{ Err error }

func (e *ConnectionError) Error() string { return "relay: connection failed: " + e.Err.Error() }

// Unwrap returns the transport error.
func (e *ConnectionError) Unwrap() error { return e.Err }

// WebhookVerificationError says why a webhook request was refused.
type WebhookVerificationError struct{ Reason string }

func (e *WebhookVerificationError) Error() string { return "relay: webhook refused: " + e.Reason }

// WaitTimeoutError says that a waitpoint did not reach a final state in time.
type WaitTimeoutError struct {
	WaitpointID string
	State       string
}

func (e *WaitTimeoutError) Error() string {
	return "relay: waitpoint " + e.WaitpointID + " is still " + e.State
}

func (c *Client) parseAPIError(resp *Response) *APIError {
	e := &APIError{
		StatusCode: resp.StatusCode,
		Title:      http.StatusText(resp.StatusCode),
		RequestID:  resp.Header.Get("Request-Id"),
		Header:     resp.Header,
	}
	var problem map[string]any
	if json.Unmarshal(resp.Body, &problem) == nil && problem != nil {
		e.Problem = problem
		e.Code = stringField(problem, "code")
		if t := stringField(problem, "title"); t != "" {
			e.Title = t
		}
		e.Detail = stringField(problem, "detail")
		e.Type = stringField(problem, "type")
		e.Instance = stringField(problem, "instance")
		if id := stringField(problem, "request_id"); id != "" {
			e.RequestID = id
		}
		if r, ok := problem["retryable"].(bool); ok {
			e.Retryable = r
		}
	}
	e.RetryAfter = parseRetryAfter(resp.Header, c.now())
	if e.RetryAfter == nil && problem != nil {
		if secs, ok := problem["retry_after"].(float64); ok && secs >= 0 {
			d := time.Duration(secs * float64(time.Second))
			e.RetryAfter = &d
		}
	}
	return e
}

func stringField(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

// X-29
func classify(e *APIError) error {
	spec, known := errorCatalog[e.Code]
	switch {
	case known && spec.family == "idempotency":
		return &IdempotencyError{e}
	case known && spec.family == "auth":
		return &AuthenticationError{e}
	case known && spec.family == "quota":
		return &RateLimitError{e}
	case e.StatusCode >= 500:
		return &ServerError{e}
	case !known && (e.StatusCode == http.StatusUnauthorized || e.StatusCode == http.StatusForbidden):
		return &AuthenticationError{e}
	case !known && e.StatusCode == http.StatusTooManyRequests:
		return &RateLimitError{e}
	case e.StatusCode == http.StatusNotFound:
		return &NotFoundError{e}
	case e.StatusCode == http.StatusConflict || e.StatusCode == http.StatusPreconditionFailed ||
		e.StatusCode == http.StatusPreconditionRequired:
		return &ConflictError{e}
	default:
		return &ValidationError{e}
	}
}
