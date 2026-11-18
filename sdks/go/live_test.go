//go:build live

package relay

import (
	"context"
	"os"
	"testing"
)

func TestX48LiveTestPlane(t *testing.T) {
	base := os.Getenv("RELAY_SDK_LIVE_BASE_URL")
	if base == "" {
		t.Skip("RELAY_SDK_LIVE_BASE_URL is not set")
	}
	cc, err := NewClientCredentials(os.Getenv("RELAY_SDK_LIVE_ISSUER"), os.Getenv("RELAY_SDK_LIVE_CLIENT_ID"), os.Getenv("RELAY_SDK_LIVE_CLIENT_SECRET"))
	if err != nil {
		t.Fatal(err)
	}
	c, err := NewClient(base, cc)
	if err != nil {
		t.Fatal(err)
	}
	var page map[string]any
	if err := c.Do(context.Background(), "GET", "/v1/notifications?limit=1", nil, &page); err != nil {
		t.Fatal(err)
	}
	if page["object"] != "list" {
		t.Fatalf("unexpected answer %v", page)
	}
}
