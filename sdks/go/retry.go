package relay

import (
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
func (p retryPolicy) delay(retry int, retryAfter *time.Duration, random float64) (time.Duration, bool) {
	ceiling := p.maxDelay
	if retry < 30 {
		if d := p.base << retry; d > 0 && d < ceiling {
			ceiling = d
		}
	}
	jitter := time.Duration(random * float64(ceiling))
	if retryAfter != nil {
		if *retryAfter > p.maxRetryAfter {
			return 0, false
		}
		if *retryAfter > jitter {
			return *retryAfter, true
		}
	}
	return jitter, true
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
