package relay

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"regexp"
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
				return nil, errors.New("relay: malformed whpk_ webhook key")
			}
			v.ed25519Keys = append(v.ed25519Keys, ed25519.PublicKey(raw))
		case strings.HasPrefix(k, "whsec_"):
			raw, err := decodeKey(strings.TrimPrefix(k, "whsec_"))
			if err != nil || len(raw) == 0 {
				return nil, errors.New("relay: malformed whsec_ webhook secret")
			}
			v.hmacKeys = append(v.hmacKeys, raw)
		default:
			return nil, errors.New("relay: a webhook key starts with whpk_ or whsec_")
		}
	}
	if len(v.ed25519Keys) == 0 && len(v.hmacKeys) == 0 {
		return nil, errors.New("relay: at least one webhook key is required")
	}
	return v, nil
}

func decodeKey(s string) ([]byte, error) {
	if raw, err := base64.StdEncoding.DecodeString(s); err == nil {
		return raw, nil
	}
	return base64.RawStdEncoding.DecodeString(s)
}

// Verify checks the webhook-id, webhook-timestamp and webhook-signature headers against the raw body as received, before it is parsed, and returns the scheme ("v1a" or "v1") of the first signature that verifies.
func (v *WebhookVerifier) Verify(body []byte, header http.Header) (string, error) {
	return v.VerifyAt(body, header, v.now())
}

var webhookTimestamp = regexp.MustCompile(`^(0|[1-9][0-9]*)$`)

func headerValues(h http.Header, name string) []string {
	var out []string
	for k, vs := range h {
		if strings.EqualFold(k, name) {
			out = append(out, vs...)
		}
	}
	return out
}

func refuse(reason string) (string, error) {
	return "", &WebhookVerificationError{Reason: reason}
}

type signatureToken struct {
	scheme string
	sig    []byte
}

// WH-7
// X-29

// VerifyAt is Verify with the receiver's clock given.
func (v *WebhookVerifier) VerifyAt(body []byte, header http.Header, now time.Time) (string, error) {
	values := make([]string, 3)
	for i, name := range []string{"webhook-id", "webhook-timestamp", "webhook-signature"} {
		found := headerValues(header, name)
		if len(found) == 0 {
			return refuse("missing_header")
		}
		if len(found) > 1 {
			return refuse("duplicate_header")
		}
		values[i] = found[0]
	}
	id, ts, sigs := values[0], values[1], values[2]
	if id == "" || !webhookTimestamp.MatchString(ts) {
		return refuse("malformed_header")
	}
	sent, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return refuse("malformed_header")
	}
	var tokens []signatureToken
	fields := strings.Fields(sigs)
	if len(fields) == 0 {
		return refuse("malformed_header")
	}
	for _, entry := range fields {
		scheme, encoded, ok := strings.Cut(entry, ",")
		if !ok || scheme == "" || encoded == "" {
			return refuse("malformed_header")
		}
		want := 0
		switch scheme {
		case "v1a":
			want = ed25519.SignatureSize
		case "v1":
			want = sha256.Size
		default:
			continue
		}
		sig, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil || len(sig) != want {
			return refuse("malformed_header")
		}
		tokens = append(tokens, signatureToken{scheme: scheme, sig: sig})
	}
	tolerance := v.Tolerance
	if tolerance <= 0 {
		tolerance = DefaultWebhookTolerance
	}
	skew := now.Sub(time.Unix(sent, 0))
	if skew > tolerance || skew < -tolerance {
		return refuse("timestamp_out_of_tolerance")
	}
	content := make([]byte, 0, len(id)+len(ts)+len(body)+2)
	content = append(content, id...)
	content = append(content, '.')
	content = append(content, ts...)
	content = append(content, '.')
	content = append(content, body...)
	var mac []byte
	for _, t := range tokens {
		switch t.scheme {
		case "v1a":
			for _, key := range v.ed25519Keys {
				if ed25519.Verify(key, content, t.sig) {
					return "v1a", nil
				}
			}
		case "v1":
			for _, key := range v.hmacKeys {
				h := hmac.New(sha256.New, key)
				h.Write(content)
				mac = h.Sum(mac[:0])
				if hmac.Equal(mac, t.sig) {
					return "v1", nil
				}
			}
		}
	}
	return refuse("no_matching_signature")
}
