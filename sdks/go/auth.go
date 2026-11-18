package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Authorizer gives the Authorization and DPoP headers of one request and forgets its token when Relay says it expired.
type Authorizer interface {
	Authorize(ctx context.Context, method, target string) (http.Header, error)
	Invalidate()
}

// ClientCredentials obtains DPoP-bound Access access tokens with the OAuth 2.0 client credentials grant for Relay's Access client_id and signs a fresh DPoP proof for every request with an Ed25519 key made for this value.
type ClientCredentials struct {
	issuer       string
	clientID     string
	clientSecret string
	scope        string
	relayURL     string
	httpClient   *http.Client
	now          func() time.Time
	key          ed25519.PrivateKey

	mu       sync.Mutex
	token    string
	expires  time.Time
	resource string
	endpoint string
	postOnly bool
}

// CredentialOption configures ClientCredentials.
type CredentialOption func(*ClientCredentials)

// WithScope narrows the token to the given space-separated scopes.
func WithScope(scope string) CredentialOption {
	return func(cc *ClientCredentials) { cc.scope = scope }
}

// WithCredentialsHTTPClient sets the HTTP client of the discovery and token requests.
func WithCredentialsHTTPClient(h *http.Client) CredentialOption {
	return func(cc *ClientCredentials) { cc.httpClient = h }
}

// WithRelayURL sets the Relay base URL whose discovery document names Relay's Access client_id; NewClient sets it otherwise.
func WithRelayURL(u string) CredentialOption {
	return func(cc *ClientCredentials) { cc.relayURL = strings.TrimRight(u, "/") }
}

// NewClientCredentials returns an Authorizer for the Access API client clientID of the Access issuer.
func NewClientCredentials(issuer, clientID, clientSecret string, opts ...CredentialOption) (*ClientCredentials, error) {
	if issuer == "" || clientID == "" || clientSecret == "" {
		return nil, fmt.Errorf("relay: issuer, client id and client secret are required")
	}
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("relay: generate DPoP key: %w", err)
	}
	cc := &ClientCredentials{
		issuer:       strings.TrimRight(issuer, "/"),
		clientID:     clientID,
		clientSecret: clientSecret,
		httpClient:   http.DefaultClient,
		now:          time.Now,
		key:          key,
	}
	for _, opt := range opts {
		opt(cc)
	}
	return cc, nil
}

func (cc *ClientCredentials) setRelayURL(u string) {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	if cc.relayURL == "" {
		cc.relayURL = u
	}
}

// Authorize returns Authorization: DPoP with the access token and a fresh DPoP proof for method and target.
func (cc *ClientCredentials) Authorize(ctx context.Context, method, target string) (http.Header, error) {
	token, err := cc.accessToken(ctx)
	if err != nil {
		return nil, err
	}
	h := http.Header{}
	h.Set("Authorization", "DPoP "+token)
	h.Set("DPoP", cc.proof(method, target, token, ""))
	return h, nil
}

// Invalidate forgets the access token; the next request obtains a new one.
func (cc *ClientCredentials) Invalidate() {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	cc.token = ""
	cc.expires = time.Time{}
}

type dpopJWK struct {
	Kty string `json:"kty"`
	Crv string `json:"crv"`
	X   string `json:"x"`
}

type dpopHeader struct {
	Typ string  `json:"typ"`
	Alg string  `json:"alg"`
	JWK dpopJWK `json:"jwk"`
}

type dpopClaims struct {
	HTM   string `json:"htm"`
	HTU   string `json:"htu"`
	IAT   int64  `json:"iat"`
	JTI   string `json:"jti"`
	ATH   string `json:"ath,omitempty"`
	Nonce string `json:"nonce,omitempty"`
}

func b64(data []byte) string {
	return base64.RawURLEncoding.EncodeToString(data)
}

func htu(target string) string {
	if i := strings.IndexAny(target, "?#"); i >= 0 {
		return target[:i]
	}
	return target
}

// E-93
func (cc *ClientCredentials) proof(method, target, token, nonce string) string {
	pub := cc.key.Public().(ed25519.PublicKey)
	header := dpopHeader{Typ: "dpop+jwt", Alg: "Ed25519", JWK: dpopJWK{Kty: "OKP", Crv: "Ed25519", X: b64(pub)}}
	jti := make([]byte, 16)
	_, _ = rand.Read(jti)
	claims := dpopClaims{HTM: method, HTU: htu(target), IAT: cc.now().Unix(), JTI: b64(jti), Nonce: nonce}
	if token != "" {
		sum := sha256.Sum256([]byte(token))
		claims.ATH = b64(sum[:])
	}
	hj, _ := json.Marshal(header)
	cj, _ := json.Marshal(claims)
	input := b64(hj) + "." + b64(cj)
	return input + "." + b64(ed25519.Sign(cc.key, []byte(input)))
}

func (cc *ClientCredentials) accessToken(ctx context.Context) (string, error) {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	if cc.token != "" && (cc.expires.IsZero() || cc.now().Before(cc.expires)) {
		return cc.token, nil
	}
	if cc.resource == "" {
		if err := cc.discoverRelay(ctx); err != nil {
			return "", err
		}
	}
	if cc.endpoint == "" {
		if err := cc.discoverAccess(ctx); err != nil {
			return "", err
		}
	}
	token, expiresIn, err := cc.requestToken(ctx, "")
	if err != nil {
		return "", err
	}
	cc.token = token
	cc.expires = time.Time{}
	if expiresIn > 30 {
		cc.expires = cc.now().Add(time.Duration(expiresIn-30) * time.Second)
	}
	return token, nil
}

func (cc *ClientCredentials) getJSON(ctx context.Context, target string, out any) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Accept", "application/json")
	res, err := cc.httpClient.Do(req)
	if err != nil {
		return 0, &ConnectionError{Err: err}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return res.StatusCode, &ConnectionError{Err: err}
	}
	if res.StatusCode != http.StatusOK {
		return res.StatusCode, nil
	}
	return res.StatusCode, json.Unmarshal(data, out)
}

func credentialError(status int, code, message string) error {
	return &AuthenticationError{&APIError{StatusCode: status, Code: code, Title: message, Detail: message}}
}

// E-81
func (cc *ClientCredentials) discoverRelay(ctx context.Context) error {
	if cc.relayURL == "" {
		return credentialError(0, "access_discovery_failed", "the Relay base URL is unknown")
	}
	var doc struct {
		AccessClientID string `json:"access_client_id"`
	}
	status, err := cc.getJSON(ctx, cc.relayURL+"/.well-known/relay-configuration", &doc)
	if err != nil {
		return err
	}
	if status != http.StatusOK || doc.AccessClientID == "" {
		return credentialError(status, "access_discovery_failed", "the Relay discovery document names no access_client_id")
	}
	cc.resource = doc.AccessClientID
	return nil
}

func (cc *ClientCredentials) discoverAccess(ctx context.Context) error {
	var doc struct {
		Issuer        string   `json:"issuer"`
		TokenEndpoint string   `json:"token_endpoint"`
		AuthMethods   []string `json:"token_endpoint_auth_methods_supported"`
	}
	status, err := cc.getJSON(ctx, cc.issuer+"/.well-known/openid-configuration", &doc)
	if err != nil {
		return err
	}
	switch {
	case status != http.StatusOK || doc.TokenEndpoint == "":
		return credentialError(status, "access_discovery_failed", "the Access discovery document has no token_endpoint")
	case strings.TrimRight(doc.Issuer, "/") != cc.issuer:
		return credentialError(status, "access_discovery_failed", "the Access discovery document names another issuer")
	case !strings.HasPrefix(doc.TokenEndpoint, "https://"):
		return credentialError(status, "access_discovery_failed", "the token endpoint is not an https URL")
	}
	basic, post := false, false
	for _, m := range doc.AuthMethods {
		basic = basic || m == "client_secret_basic"
		post = post || m == "client_secret_post"
	}
	cc.endpoint = doc.TokenEndpoint
	cc.postOnly = post && !basic
	return nil
}

var oauthErrorCode = regexp.MustCompile(`^[a-z_]{1,64}$`)

// E-93
func (cc *ClientCredentials) requestToken(ctx context.Context, nonce string) (string, int64, error) {
	form := url.Values{"grant_type": {"client_credentials"}, "resource": {cc.resource}}
	if cc.scope != "" {
		form.Set("scope", cc.scope)
	}
	if cc.postOnly {
		form.Set("client_id", cc.clientID)
		form.Set("client_secret", cc.clientSecret)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cc.endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("DPoP", cc.proof(http.MethodPost, cc.endpoint, "", nonce))
	if !cc.postOnly {
		creds := url.QueryEscape(cc.clientID) + ":" + url.QueryEscape(cc.clientSecret)
		req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(creds)))
	}
	res, err := cc.httpClient.Do(req)
	if err != nil {
		return "", 0, &ConnectionError{Err: err}
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return "", 0, &ConnectionError{Err: err}
	}
	var body struct {
		AccessToken      string `json:"access_token"`
		TokenType        string `json:"token_type"`
		ExpiresIn        int64  `json:"expires_in"`
		Error            string `json:"error"`
		ErrorDescription string `json:"error_description"`
	}
	_ = json.Unmarshal(data, &body)
	switch {
	case res.StatusCode == http.StatusOK:
		if body.AccessToken == "" {
			return "", 0, credentialError(res.StatusCode, "access_token_refused", "Access answered without a DPoP access token")
		}
		if !strings.EqualFold(body.TokenType, "DPoP") {
			return "", 0, credentialError(res.StatusCode, "access_token_refused", "Access issued a "+body.TokenType+" token, not a DPoP token")
		}
		return body.AccessToken, body.ExpiresIn, nil
	case res.StatusCode == http.StatusBadRequest && body.Error == "use_dpop_nonce" && nonce == "":
		next := res.Header.Get("DPoP-Nonce")
		if next == "" {
			return "", 0, credentialError(res.StatusCode, "access_token_refused", "Access asked for a DPoP nonce without naming one")
		}
		return cc.requestToken(ctx, next)
	case res.StatusCode == http.StatusTooManyRequests || res.StatusCode >= 500:
		return "", 0, &ServerError{&APIError{StatusCode: res.StatusCode, Code: "access_unavailable", Title: "Access is unavailable"}}
	default:
		code := "token_refused"
		if oauthErrorCode.MatchString(body.Error) {
			code = body.Error
		}
		message := "Access refused the client credentials"
		if body.ErrorDescription != "" {
			message += ": " + body.ErrorDescription
		}
		return "", 0, credentialError(res.StatusCode, "access_"+code, message)
	}
}
