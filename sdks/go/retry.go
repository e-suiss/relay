package relay

import (
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type retryPolicy struct {
	base          time.Duration
	maxDelay      time.Duration
	maxRetryAfter time.Duration
}

var defaultRetryPolicy = retryPolicy{
	base:          500 * time.Millisecond,
	maxDelay:      8 * time.Second,
	maxRetryAfter: 60 * time.Second,
}

// X-29
func (p retryPolicy) decide(retry, maxRetries int, retryable bool, retryAfter *time.Duration, random float64) (time.Duration, string) {
	if !retryable {
		return 0, "not_retryable"
	}
	if retry > maxRetries {
		return 0, "retries_exhausted"
	}
	if retryAfter != nil {
		if *retryAfter > p.maxRetryAfter {
			return 0, "retry_after_too_long"
		}
		return *retryAfter, ""
	}
	return p.backoff(retry, random), ""
}

func (p retryPolicy) backoff(retry int, random float64) time.Duration {
	ceiling := p.maxDelay
	if retry >= 1 && retry <= 30 {
		if d := p.base << (retry - 1); d > 0 && d < ceiling {
			ceiling = d
		}
	}
	ms := math.Floor(random * float64(ceiling/time.Millisecond))
	return time.Duration(ms) * time.Millisecond
}

func parseRetryAfter(header http.Header, now time.Time) *time.Duration {
	v := strings.TrimSpace(header.Get("Retry-After"))
	if v == "" {
		return nil
	}
	if secs, err := strconv.ParseInt(v, 10, 64); err == nil {
		if secs < 0 {
			return nil
		}
		d := time.Duration(secs) * time.Second
		return &d
	}
	if t, err := http.ParseTime(v); err == nil {
		d := t.Sub(now)
		if d < 0 {
			d = 0
		}
		return &d
	}
	return nil
}
