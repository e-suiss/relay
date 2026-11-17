package relay

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// DefaultWebhookTolerance is how far webhook-timestamp may be from the receiver's clock.
const DefaultWebhookTolerance = 5 * time.Minute

// WebhookVerifier checks the Suiss webhook profile signatures over the raw request body: v1a (Ed25519, keys whpk_...) and v1 (HMAC-SHA-256, secrets whsec_...). Several keys may be given during a rotation.
type WebhookVerifier struct {
	Tolerance time.Duration

	ed25519Keys []ed25519.PublicKey
	hmacKeys    [][]byte
	now         func() time.Time
}

// NewWebhookVerifier returns a verifier for the given whpk_ public keys and whsec_ secrets.
func NewWebhookVerifier(keys ...string) (*WebhookVerifier, error) {
	v := &WebhookVerifier{Tolerance: DefaultWebhookTolerance, now: time.Now}
	for _, k := range keys {
		switch {
		case strings.HasPrefix(k, "whpk_"):
			raw, err := decodeKey(strings.TrimPrefix(k, "whpk_"))
			if err != nil || len(raw) != ed25519.PublicKeySize {
				return nil, fmt.Errorf("relay: malformed whpk_ webhook key")
			}
			v.ed25519Keys = append(v.ed25519Keys, ed25519.PublicKey(raw))
		case strings.HasPrefix(k, "whsec_"):
			raw, err := decodeKey(strings.TrimPrefix(k, "whsec_"))
			if err != nil || len(raw) == 0 {
				return nil, fmt.Errorf("relay: malformed whsec_ webhook secret")
			}
			v.hmacKeys = append(v.hmacKeys, raw)
		default:
			return nil, fmt.Errorf("relay: a webhook key starts with whpk_ or whsec_")
		}
	}
	if len(v.ed25519Keys) == 0 && len(v.hmacKeys) == 0 {
		return nil, fmt.Errorf("relay: at least one webhook key is required")
	}
	return v, nil
}

func decodeKey(s string) ([]byte, error) {
	if raw, err := base64.StdEncoding.DecodeString(s); err == nil {
		return raw, nil
	}
	return base64.RawStdEncoding.DecodeString(s)
}

// Verify checks the webhook-id, webhook-timestamp and webhook-signature headers against the raw body as received, before it is parsed.
func (v *WebhookVerifier) Verify(body []byte, header http.Header) error {
	return v.VerifyAt(body, header, v.now())
}

// WH-7
// X-29

// VerifyAt is Verify with the receiver's clock given.
func (v *WebhookVerifier) VerifyAt(body []byte, header http.Header, now time.Time) error {
	id := header.Get("webhook-id")
	ts := header.Get("webhook-timestamp")
	sigs := header.Get("webhook-signature")
	if id == "" || ts == "" || sigs == "" {
		return &WebhookVerificationError{Reason: "missing webhook-id, webhook-timestamp or webhook-signature"}
	}
	sent, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return &WebhookVerificationError{Reason: "malformed webhook-timestamp"}
	}
	tolerance := v.Tolerance
	if tolerance <= 0 {
		tolerance = DefaultWebhookTolerance
	}
	skew := now.Sub(time.Unix(sent, 0))
	if skew > tolerance || skew < -tolerance {
		return &WebhookVerificationError{Reason: "webhook-timestamp outside the tolerance"}
	}
	content := make([]byte, 0, len(id)+len(ts)+len(body)+2)
	content = append(content, id...)
	content = append(content, '.')
	content = append(content, ts...)
	content = append(content, '.')
	content = append(content, body...)
	var mac []byte
	for _, entry := range strings.Fields(sigs) {
		version, encoded, ok := strings.Cut(entry, ",")
		if !ok {
			continue
		}
		sig, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			continue
		}
		switch version {
		case "v1a":
			for _, key := range v.ed25519Keys {
				if len(sig) == ed25519.SignatureSize && ed25519.Verify(key, content, sig) {
					return nil
				}
			}
		case "v1":
			for _, key := range v.hmacKeys {
				h := hmac.New(sha256.New, key)
				h.Write(content)
				mac = h.Sum(mac[:0])
				if hmac.Equal(mac, sig) {
					return nil
				}
			}
		}
	}
	return &WebhookVerificationError{Reason: "no valid signature"}
}
