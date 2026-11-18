package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

type decodedProof struct {
	header dpopHeader
	claims dpopClaims
}

func decodeProof(t *testing.T, proof string) decodedProof {
	t.Helper()
	parts := strings.Split(proof, ".")
	if len(parts) != 3 {
		t.Fatalf("proof %q is not a compact JWS", proof)
	}
	var d decodedProof
	for i, dst := range []any{&d.header, &d.claims} {
		raw, err := base64.RawURLEncoding.DecodeString(parts[i])
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(raw, dst); err != nil {
			t.Fatal(err)
		}
	}
	pub, err := base64.RawURLEncoding.DecodeString(d.header.JWK.X)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		t.Fatalf("jwk x %q", d.header.JWK.X)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || !ed25519.Verify(ed25519.PublicKey(pub), []byte(parts[0]+"."+parts[1]), sig) {
		t.Fatal("proof signature does not verify")
	}
	if d.header.Typ != "dpop+jwt" || d.header.Alg != "Ed25519" || d.header.JWK.Kty != "OKP" || d.header.JWK.Crv != "Ed25519" {
		t.Fatalf("proof header %+v", d.header)
	}
	return d
}

type accessStub struct {
	mu          sync.Mutex
	server      *httptest.Server
	tokenProofs []string
	apiProofs   []string
	tokens      int
	issuer      string
	methods     []string
}

func newAccessStub(t *testing.T) *accessStub {
	t.Helper()
	s := &accessStub{methods: []string{"client_secret_basic", "client_secret_post"}}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/relay-configuration", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_client_id":"relay-client"}`))
	})
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		s.mu.Lock()
		issuer := s.issuer
		methods := s.methods
		s.mu.Unlock()
		if issuer == "" {
			issuer = s.server.URL
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                                issuer,
			"token_endpoint":                        s.server.URL + "/oauth2/token",
			"token_endpoint_auth_methods_supported": methods,
		})
	})
	mux.HandleFunc("/oauth2/token", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		id, secret, ok := r.BasicAuth()
		_ = r.ParseForm()
		if !ok || id != "client-1" || secret != "s3cret" || r.PostForm.Get("grant_type") != "client_credentials" ||
			r.PostForm.Get("resource") != "relay-client" || r.PostForm.Get("scope") != "publish" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"invalid_client"}`))
			return
		}
		s.tokenProofs = append(s.tokenProofs, r.Header.Get("DPoP"))
		if len(s.tokenProofs) == 1 {
			w.Header().Set("DPoP-Nonce", "n-1")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"use_dpop_nonce"}`))
			return
		}
		s.tokens++
		_, _ = w.Write([]byte(`{"access_token":"at-1","token_type":"DPoP","expires_in":300}`))
	})
	mux.HandleFunc("/v1/things", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		if r.Header.Get("Authorization") != "DPoP at-1" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		s.apiProofs = append(s.apiProofs, r.Header.Get("DPoP"))
		_, _ = w.Write([]byte(`{}`))
	})
	s.server = httptest.NewTLSServer(mux)
	t.Cleanup(s.server.Close)
	return s
}

func TestE93ClientCredentialsDPoPFlow(t *testing.T) {
	s := newAccessStub(t)
	cc, err := NewClientCredentials(s.server.URL+"/", "client-1", "s3cret", WithScope("publish"), WithCredentialsHTTPClient(s.server.Client()))
	if err != nil {
		t.Fatal(err)
	}
	c, err := NewClient(s.server.URL, cc, WithHTTPClient(s.server.Client()))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := c.Do(context.Background(), "GET", "/v1/things?limit=2", nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.tokenProofs) != 2 || s.tokens != 1 || len(s.apiProofs) != 2 {
		t.Fatalf("token proofs %d, tokens %d, api proofs %d", len(s.tokenProofs), s.tokens, len(s.apiProofs))
	}
	first := decodeProof(t, s.tokenProofs[0])
	second := decodeProof(t, s.tokenProofs[1])
	if first.claims.Nonce != "" || second.claims.Nonce != "n-1" || second.claims.ATH != "" {
		t.Fatalf("token proofs %+v %+v", first.claims, second.claims)
	}
	if second.claims.HTM != "POST" || second.claims.HTU != s.server.URL+"/oauth2/token" {
		t.Fatalf("token proof claims %+v", second.claims)
	}
	api := decodeProof(t, s.apiProofs[0])
	sum := sha256.Sum256([]byte("at-1"))
	if api.claims.HTM != "GET" || api.claims.HTU != s.server.URL+"/v1/things" || api.claims.ATH != base64.RawURLEncoding.EncodeToString(sum[:]) {
		t.Fatalf("api proof claims %+v", api.claims)
	}
	if api.claims.JTI == decodeProof(t, s.apiProofs[1]).claims.JTI || len(api.claims.JTI) < 16 {
		t.Fatal("jti reused")
	}
	if api.header.JWK.X != first.header.JWK.X {
		t.Fatal("the token and the API proofs use different keys")
	}
}

func TestE93ClientCredentialsRefusesAnotherIssuer(t *testing.T) {
	s := newAccessStub(t)
	s.issuer = "https://elsewhere.example"
	cc, _ := NewClientCredentials(s.server.URL, "client-1", "s3cret", WithScope("publish"), WithCredentialsHTTPClient(s.server.Client()))
	c, _ := NewClient(s.server.URL, cc, WithHTTPClient(s.server.Client()))
	err := c.Do(context.Background(), "GET", "/v1/things", nil, nil)
	var authErr *AuthenticationError
	if !errors.As(err, &authErr) || authErr.Code != "access_discovery_failed" {
		t.Fatalf("got %v", err)
	}
}
