package relay

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type signatureVectors struct {
	Keys struct {
		Ed25519PublicKey string `json:"ed25519_public_key"`
		HMACSecret       string `json:"hmac_secret"`
	} `json:"keys"`
	ToleranceS int64 `json:"tolerance_s"`
	Cases      []struct {
		Name             string `json:"name"`
		WebhookID        string `json:"webhook_id"`
		WebhookTimestamp int64  `json:"webhook_timestamp"`
		BodyHex          string `json:"body_hex"`
		V1a              string `json:"v1a"`
		V1               string `json:"v1"`
	} `json:"cases"`
	Rejections []struct {
		Name         string  `json:"name"`
		Case         string  `json:"case"`
		BodyHex      *string `json:"body_hex"`
		WebhookID    *string `json:"webhook_id"`
		Now          *int64  `json:"now"`
		SwapVersions bool    `json:"swap_versions"`
	} `json:"rejections"`
}

func loadSignatureVectors(t *testing.T) signatureVectors {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "conformance", "webhooks", "vectors", "1", "signature.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v signatureVectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func webhookHeader(id string, ts int64, sigs ...string) http.Header {
	h := http.Header{}
	h.Set("webhook-id", id)
	h.Set("webhook-timestamp", strconv.FormatInt(ts, 10))
	h.Set("webhook-signature", strings.Join(sigs, " "))
	return h
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestWH7WebhookSignatureVectorsAccept(t *testing.T) {
	v := loadSignatureVectors(t)
	if time.Duration(v.ToleranceS)*time.Second != DefaultWebhookTolerance {
		t.Fatalf("default tolerance %v, vectors say %ds", DefaultWebhookTolerance, v.ToleranceS)
	}
	both, err := NewWebhookVerifier(v.Keys.Ed25519PublicKey, v.Keys.HMACSecret)
	if err != nil {
		t.Fatal(err)
	}
	edOnly, _ := NewWebhookVerifier(v.Keys.Ed25519PublicKey)
	hmacOnly, _ := NewWebhookVerifier(v.Keys.HMACSecret)
	for _, c := range v.Cases {
		body := mustHex(t, c.BodyHex)
		now := time.Unix(c.WebhookTimestamp, 0)
		checks := []struct {
			verifier *WebhookVerifier
			sigs     []string
			ok       bool
		}{
			{both, []string{c.V1a, c.V1}, true},
			{both, []string{c.V1a}, true},
			{both, []string{c.V1}, true},
			{edOnly, []string{c.V1a}, true},
			{edOnly, []string{c.V1}, false},
			{hmacOnly, []string{c.V1}, true},
			{hmacOnly, []string{c.V1a}, false},
		}
		for i, check := range checks {
			_, err := check.verifier.VerifyAt(body, webhookHeader(c.WebhookID, c.WebhookTimestamp, check.sigs...), now)
			if (err == nil) != check.ok {
				t.Errorf("%s check %d: got %v", c.Name, i, err)
			}
		}
	}
}

func TestWH7WebhookSignatureVectorsReject(t *testing.T) {
	v := loadSignatureVectors(t)
	verifier, err := NewWebhookVerifier(v.Keys.Ed25519PublicKey, v.Keys.HMACSecret)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range v.Rejections {
		found := false
		for _, c := range v.Cases {
			if c.Name != r.Case {
				continue
			}
			found = true
			body := mustHex(t, c.BodyHex)
			if r.BodyHex != nil {
				body = mustHex(t, *r.BodyHex)
			}
			id := c.WebhookID
			if r.WebhookID != nil {
				id = *r.WebhookID
			}
			now := time.Unix(c.WebhookTimestamp, 0)
			if r.Now != nil {
				now = time.Unix(*r.Now, 0)
			}
			sigs := []string{c.V1a, c.V1}
			if r.SwapVersions {
				_, a, _ := strings.Cut(c.V1a, ",")
				_, h, _ := strings.Cut(c.V1, ",")
				sigs = []string{"v1a," + h, "v1," + a}
			}
			_, err := verifier.VerifyAt(body, webhookHeader(id, c.WebhookTimestamp, sigs...), now)
			var verr *WebhookVerificationError
			if err == nil || !errors.As(err, &verr) {
				t.Errorf("%s: accepted (%v)", r.Name, err)
			}
		}
		if !found {
			t.Fatalf("%s names unknown case %s", r.Name, r.Case)
		}
	}
}

func TestWH7WebhookMissingHeadersAndBadKeys(t *testing.T) {
	v := loadSignatureVectors(t)
	verifier, _ := NewWebhookVerifier(v.Keys.HMACSecret)
	if _, err := verifier.VerifyAt([]byte("{}"), http.Header{}, time.Now()); err == nil {
		t.Fatal("accepted a request without headers")
	}
	if _, err := NewWebhookVerifier("nope"); err == nil {
		t.Fatal("accepted a key without prefix")
	}
	if _, err := NewWebhookVerifier(); err == nil {
		t.Fatal("accepted no keys")
	}
}
