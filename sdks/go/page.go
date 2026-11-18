package relay

import (
	"context"
	"iter"
	"slices"
)

// Page is one page of a cursor-paginated list. Next fetches the following page: towards older items with starting_after, or, for a list started with ending_before, towards newer items. All and the generated Iter methods iterate items lazily, fetching a page only when the previous one is used up; backward iteration yields each page's items in reverse order.
type Page[T any] struct {
	Data           []T
	HasMore        bool
	NextCursor     *string
	PreviousCursor *string

	client *Client
	req    *request
	opts   []RequestOption
}

type pageEnvelope[T any] struct {
	Data           []T     `json:"data"`
	HasMore        bool    `json:"has_more"`
	NextCursor     *string `json:"next_cursor"`
	PreviousCursor *string `json:"previous_cursor"`
}

// API-56
func fetchPage[T any](ctx context.Context, c *Client, r *request, opts []RequestOption) (*Page[T], error) {
	if r.query.Has("starting_after") && r.query.Has("ending_before") {
		return nil, ErrBothCursors
	}
	resp, err := c.send(ctx, r, opts)
	if err != nil {
		return nil, err
	}
	var env pageEnvelope[T]
	if err := decodeJSON(resp, &env); err != nil {
		return nil, err
	}
	return &Page[T]{
		Data:           env.Data,
		HasMore:        env.HasMore,
		NextCursor:     env.NextCursor,
		PreviousCursor: env.PreviousCursor,
		client:         c,
		req:            r,
		opts:           opts,
	}, nil
}

func (p *Page[T]) backward() bool {
	return p.req.query.Has("ending_before")
}

// HasNext reports whether another page follows in the direction of iteration.
func (p *Page[T]) HasNext() bool {
	if p.backward() {
		return p.PreviousCursor != nil && *p.PreviousCursor != ""
	}
	return p.HasMore && p.NextCursor != nil && *p.NextCursor != ""
}

// Next fetches the following page with the same parameters; it returns nil and no error after the last page.
func (p *Page[T]) Next(ctx context.Context) (*Page[T], error) {
	if !p.HasNext() {
		return nil, nil
	}
	r := p.req.clone()
	if p.backward() {
		r.query.Set("ending_before", *p.PreviousCursor)
	} else {
		r.query.Set("starting_after", *p.NextCursor)
	}
	return fetchPage[T](ctx, p.client, r, p.opts)
}

// All iterates the items of this page and of every following page.
func (p *Page[T]) All(ctx context.Context) iter.Seq2[T, error] {
	return pageIter(ctx, func() (*Page[T], error) { return p, nil })
}

func pageIter[T any](ctx context.Context, first func() (*Page[T], error)) iter.Seq2[T, error] {
	return func(yield func(T, error) bool) {
		page, err := first()
		for {
			if err != nil {
				var zero T
				yield(zero, err)
				return
			}
			if page == nil {
				return
			}
			data := page.Data
			if page.backward() {
				data = slices.Clone(data)
				slices.Reverse(data)
			}
			for _, item := range data {
				if !yield(item, nil) {
					return
				}
			}
			page, err = page.Next(ctx)
		}
	}
}
