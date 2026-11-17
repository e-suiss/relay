package relay

import (
	"context"
	"errors"
	"iter"
	"regexp"
	"strconv"
	"sync"
	"time"
)

// X-30
// AG-21

// OpenWaitpoint creates a waitpoint under key, a fresh idempotency key when empty, and returns the key: the key is the waitpoint's identity, so calling again with it after a failure keeps the same waitpoint and deadline.
func (c *Client) OpenWaitpoint(ctx context.Context, body *WaitpointCreate, key string, opts ...RequestOption) (*Waitpoint, string, error) {
	if key == "" {
		key = c.newKey()
	}
	wp, err := c.CreateWaitpoint(ctx, body, append(opts, WithIdempotencyKey(key))...)
	return wp, key, err
}

func waitpointFinal(state string) bool {
	return state == "resolved" || state == "expired" || state == "cancelled"
}

// AwaitWaitpoint polls the waitpoint every pollInterval (2 seconds when zero) until it is resolved, expired or cancelled, sending the waiter heartbeat at half its heartbeat_interval; after timeout it returns the last waitpoint with a *WaitTimeoutError.
func (c *Client) AwaitWaitpoint(ctx context.Context, waitpointID string, timeout, pollInterval time.Duration) (*Waitpoint, error) {
	if pollInterval <= 0 {
		pollInterval = 2 * time.Second
	}
	deadline := c.now().Add(timeout)
	var lastBeat time.Time
	for {
		wp, err := c.GetWaitpoint(ctx, waitpointID)
		if err != nil {
			return nil, err
		}
		if waitpointFinal(string(wp.State)) {
			return wp, nil
		}
		now := c.now()
		wait := pollInterval
		if wp.HeartbeatInterval != nil {
			if every, ok := parseISODuration(string(*wp.HeartbeatInterval)); ok && every > 0 {
				half := every / 2
				if lastBeat.IsZero() || now.Sub(lastBeat) >= half {
					if _, err := c.HeartbeatWaitpoint(ctx, waitpointID); err != nil {
						var refused *APIError
						if !errors.As(err, &refused) || refused.StatusCode != 409 {
							return nil, err
						}
					}
					lastBeat = now
				}
				if half > 0 && half < wait {
					wait = half
				}
			}
		}
		left := deadline.Sub(now)
		if left <= 0 {
			return wp, &WaitTimeoutError{WaitpointID: waitpointID, State: string(wp.State)}
		}
		if left < wait {
			wait = left
		}
		if err := c.sleep(ctx, wait); err != nil {
			return nil, err
		}
	}
}

var isoDuration = regexp.MustCompile(`^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$`)

func parseISODuration(s string) (time.Duration, bool) {
	m := isoDuration.FindStringSubmatch(s)
	if m == nil || s == "P" || s == "PT" {
		return 0, false
	}
	units := []time.Duration{7 * 24 * time.Hour, 24 * time.Hour, time.Hour, time.Minute, time.Second}
	var total time.Duration
	for i, unit := range units {
		if m[i+1] == "" {
			continue
		}
		n, err := strconv.ParseInt(m[i+1], 10, 64)
		if err != nil {
			return 0, false
		}
		total += time.Duration(n) * unit
	}
	return total, true
}

// ReadMailbox reads the caller's mailbox records after since (the acknowledged position when empty), at most limit of them (the server default when zero), without taking a lease.
func (c *Client) ReadMailbox(ctx context.Context, since string, limit int64, opts ...RequestOption) (*MailboxRecords, error) {
	p := &ListMailboxRecordsParams{}
	if since != "" {
		p.Since = &since
	}
	if limit > 0 {
		p.Limit = &limit
	}
	return c.ListMailboxRecords(ctx, p, opts...)
}

// MailboxRecordsSince iterates the caller's mailbox records after since in stream order, following the cursor until the mailbox is read up and starting over from the given cursor when Relay asks for a resync.
func (c *Client) MailboxRecordsSince(ctx context.Context, since string) iter.Seq2[MailboxRecord, error] {
	return func(yield func(MailboxRecord, error) bool) {
		cursor := since
		for {
			page, err := c.ReadMailbox(ctx, cursor, 0)
			if err != nil {
				yield(MailboxRecord{}, err)
				return
			}
			for _, rec := range page.Records {
				if !yield(rec, nil) {
					return
				}
			}
			next := string(page.Cursor)
			if next == "" || next == cursor && !page.ResyncRequired {
				return
			}
			cursor = next
			if !page.HasMore && !page.ResyncRequired {
				return
			}
		}
	}
}

// LeaseMailbox leases at most maxRecords records of the caller's mailbox; records not acknowledged within the lease are handed out again.
func (c *Client) LeaseMailbox(ctx context.Context, maxRecords int64, opts ...RequestOption) (*MailboxLease, error) {
	return c.LeaseMailboxRecords(ctx, &MailboxLeaseRequest{Max: &maxRecords}, opts...)
}

// AckMailbox acknowledges records of one lease.
func (c *Client) AckMailbox(ctx context.Context, leaseID string, recordIDs []string, opts ...RequestOption) (*MailboxAck, error) {
	return c.AckMailboxRecords(ctx, &MailboxAckRequest{LeaseID: leaseID, RecordIDs: recordIDs}, opts...)
}

// MergeStreamAndHistory implements the open-then-list-then-deduplicate pattern: open the stream before calling it, and it buffers the stream while history is listed, yields history, then the stream, dropping any item whose version is not above the highest version already yielded for its key.
func MergeStreamAndHistory[T any](ctx context.Context, stream <-chan T, history iter.Seq2[T, error], key func(T) string, version func(T) int64) iter.Seq2[T, error] {
	return func(yield func(T, error) bool) {
		ctx, cancel := context.WithCancel(ctx)
		defer cancel()
		buf := newStreamBuffer(ctx, stream)
		seen := map[string]int64{}
		emit := func(item T) bool {
			k, v := key(item), version(item)
			if last, ok := seen[k]; ok && v <= last {
				return true
			}
			seen[k] = v
			return yield(item, nil)
		}
		for item, err := range history {
			if err != nil {
				var zero T
				yield(zero, err)
				return
			}
			if !emit(item) {
				return
			}
		}
		for {
			item, ok := buf.next(ctx)
			if !ok {
				if err := ctx.Err(); err != nil {
					var zero T
					yield(zero, err)
				}
				return
			}
			if !emit(item) {
				return
			}
		}
	}
}

// MergeMailbox applies MergeStreamAndHistory to mailbox records: stream holds records announced by wake hints, history is read after since, records are deduplicated by id and ordered by seq.
func (c *Client) MergeMailbox(ctx context.Context, stream <-chan MailboxRecord, since string) iter.Seq2[MailboxRecord, error] {
	return MergeStreamAndHistory(ctx, stream, c.MailboxRecordsSince(ctx, since),
		func(r MailboxRecord) string { return string(r.ID) },
		func(r MailboxRecord) int64 { return r.Seq })
}

type streamBuffer[T any] struct {
	mu     sync.Mutex
	items  []T
	closed bool
	signal chan struct{}
}

func newStreamBuffer[T any](ctx context.Context, stream <-chan T) *streamBuffer[T] {
	b := &streamBuffer[T]{signal: make(chan struct{}, 1)}
	go func() {
		defer b.close()
		for {
			select {
			case <-ctx.Done():
				return
			case item, ok := <-stream:
				if !ok {
					return
				}
				b.mu.Lock()
				b.items = append(b.items, item)
				b.mu.Unlock()
				b.notify()
			}
		}
	}()
	return b
}

func (b *streamBuffer[T]) notify() {
	select {
	case b.signal <- struct{}{}:
	default:
	}
}

func (b *streamBuffer[T]) close() {
	b.mu.Lock()
	b.closed = true
	b.mu.Unlock()
	b.notify()
}

func (b *streamBuffer[T]) next(ctx context.Context) (T, bool) {
	for {
		b.mu.Lock()
		if len(b.items) > 0 {
			item := b.items[0]
			b.items = b.items[1:]
			b.mu.Unlock()
			return item, true
		}
		closed := b.closed
		b.mu.Unlock()
		if closed {
			var zero T
			return zero, false
		}
		select {
		case <-ctx.Done():
			var zero T
			return zero, false
		case <-b.signal:
		}
	}
}
