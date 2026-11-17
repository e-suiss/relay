package relay

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"
)

type errorSpec struct {
	family    string
	status    int
	retryable bool
}

// ErrBothCursors is returned before any request when a list call sets both starting_after and ending_before.
var ErrBothCursors = errors.New("relay: starting_after and ending_before cannot both be set")

// ProblemFieldError is one field error of a validation problem.
type ProblemFieldError struct {
	Pointer string `json:"pointer"`
	Code    string `json:"code"`
	Detail  string `json:"detail"`
}

// APIError is an error answer of Relay, normally an RFC 9457 problem. Every typed error wraps one, so errors.As with *APIError reaches the fields of any of them.
type APIError struct {
	StatusCode  int
	Code        string
	Title       string
	Detail      string
	Type        string
	Instance    string
	RequestID   string
	Retryable   bool
	RetryAfter  *time.Duration
	FieldErrors []ProblemFieldError
	Problem     map[string]any
	Header      http.Header
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

// AuthenticationError is a problem of the auth family: missing, invalid or expired credentials, scope, role, step-up or suspension.
type AuthenticationError struct{ *APIError }

// Unwrap returns the problem.
func (e *AuthenticationError) Unwrap() error { return e.APIError }

// ValidationError is a client error of any other family: a malformed request, a failed validation, a missing resource or a conflict.
type ValidationError struct{ *APIError }

// Unwrap returns the problem.
func (e *ValidationError) Unwrap() error { return e.APIError }

// RateLimitError is a problem of the quota family: a rate limit, an exhausted quota or a batch above its limit.
type RateLimitError struct{ *APIError }

// Unwrap returns the problem.
func (e *RateLimitError) Unwrap() error { return e.APIError }

// IdempotencyError is a problem of the idempotency family: a missing, invalid, reused or in-progress Idempotency-Key.
type IdempotencyError struct{ *APIError }

// Unwrap returns the problem.
func (e *IdempotencyError) Unwrap() error { return e.APIError }

// ServerError is a problem of the platform family or any other 5xx answer.
type ServerError struct{ *APIError }

// Unwrap returns the problem.
func (e *ServerError) Unwrap() error { return e.APIError }

// ConnectionError is a failure to reach Relay or Access, or to read the answer.
type ConnectionError struct{ Err error }

func (e *ConnectionError) Error() string { return "relay: connection failed: " + e.Err.Error() }

// Unwrap returns the transport error.
func (e *ConnectionError) Unwrap() error { return e.Err }

// WebhookVerificationError says why a webhook request was refused: missing_header, duplicate_header, malformed_header, timestamp_out_of_tolerance or no_matching_signature.
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

// X-29
func parseAPIError(resp *Response, now time.Time) *APIError {
	e := &APIError{
		StatusCode: resp.StatusCode,
		Title:      http.StatusText(resp.StatusCode),
		RequestID:  resp.Header.Get("Request-Id"),
		Header:     resp.Header,
	}
	retryable, hasRetryable := false, false
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
		retryable, hasRetryable = problem["retryable"].(bool)
		if raw, ok := problem["errors"]; ok {
			if data, err := json.Marshal(raw); err == nil {
				_ = json.Unmarshal(data, &e.FieldErrors)
			}
		}
	}
	if hasRetryable {
		e.Retryable = retryable
	} else {
		e.Retryable = statusRetryable[resp.StatusCode]
	}
	e.RetryAfter = parseRetryAfter(resp.Header, now)
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

var familyClasses = map[string]string{
	"auth":        "auth",
	"quota":       "rate_limit",
	"idempotency": "idempotency",
	"platform":    "server",
}

func errorClass(code string, status int) string {
	if spec, ok := errorCatalog[code]; ok {
		if class, ok := familyClasses[spec.family]; ok {
			return class
		}
		if status >= 500 {
			return "server"
		}
		return "validation"
	}
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		return "auth"
	case status == http.StatusTooManyRequests:
		return "rate_limit"
	case status >= 500:
		return "server"
	default:
		return "validation"
	}
}

// X-29
func classify(e *APIError) error {
	switch errorClass(e.Code, e.StatusCode) {
	case "auth":
		return &AuthenticationError{e}
	case "rate_limit":
		return &RateLimitError{e}
	case "idempotency":
		return &IdempotencyError{e}
	case "server":
		return &ServerError{e}
	default:
		return &ValidationError{e}
	}
}
