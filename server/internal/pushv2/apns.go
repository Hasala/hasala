package pushv2

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strconv"
	"sync"
	"time"
)

const Payload = `{"aps":{"content-available":1}}`

const (
	ProductionHost = "https://api.push.apple.com"
	SandboxHost    = "https://api.sandbox.push.apple.com"
)

const (
	EnvProduction = "production"
	EnvSandbox    = "sandbox"
)

const (
	jwtMaxAge         = 40 * time.Minute
	jwtRegenerateFrom = 20 * time.Minute
	sendTimeout       = 10 * time.Second
	expirationWindow  = time.Hour
)

type Result uint8

const (
	ResultSent Result = iota + 1
	ResultGone
	ResultCooldown
	ResultConfig
	ResultEnvironment
	ResultTransient
)

func (r Result) String() string {
	switch r {
	case ResultSent:
		return "sent"
	case ResultGone:
		return "gone"
	case ResultCooldown:
		return "cooldown"
	case ResultConfig:
		return "config"
	case ResultEnvironment:
		return "environment"
	case ResultTransient:
		return "transient"
	}
	return "unknown"
}

var ErrKeyType = errors.New("pushv2: the APNs key must be a PKCS#8 PEM EC P-256 private key")

func ParseP8(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, rest := pem.Decode(pemBytes)
	if block == nil || block.Type != "PRIVATE KEY" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, ErrKeyType
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, ErrKeyType
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok || ec.Curve != elliptic.P256() {
		return nil, ErrKeyType
	}
	return ec, nil
}

type Client struct {
	teamID, keyID, topic string
	key                  *ecdsa.PrivateKey
	http                 *http.Client
	hosts                map[string]string
	now                  func() time.Time

	mu       sync.Mutex
	jwt      string
	jwtIssue time.Time
}

type ClientConfig struct {
	TeamID, KeyID, Topic string
	Key                  *ecdsa.PrivateKey
	HTTP                 *http.Client
	Hosts                map[string]string
	Now                  func() time.Time
}

func NewClient(cfg ClientConfig) (*Client, error) {
	if cfg.Key == nil || cfg.Key.Curve != elliptic.P256() {
		return nil, ErrKeyType
	}
	if cfg.TeamID == "" || cfg.KeyID == "" || cfg.Topic == "" {
		return nil, errors.New("pushv2: APNs team id, key id and topic are required")
	}
	c := &Client{teamID: cfg.TeamID, keyID: cfg.KeyID, topic: cfg.Topic, key: cfg.Key, http: cfg.HTTP,
		hosts: cfg.Hosts, now: cfg.Now}
	if c.now == nil {
		c.now = time.Now
	}
	if c.http == nil {
		c.http = &http.Client{
			Timeout: sendTimeout,
			Transport: &http.Transport{
				ForceAttemptHTTP2:   true,
				MaxIdleConnsPerHost: 4,
				DisableCompression:  true,
			},
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
	if c.hosts == nil {
		c.hosts = map[string]string{EnvProduction: ProductionHost, EnvSandbox: SandboxHost}
	}
	return c, nil
}

func (c *Client) providerToken(refused string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	age := now.Sub(c.jwtIssue)
	if c.jwt != "" && age < jwtMaxAge && (c.jwt != refused || age < jwtRegenerateFrom) {
		return c.jwt, nil
	}
	tok, err := SignJWT(c.key, c.keyID, c.teamID, now)
	if err != nil {
		return "", err
	}
	c.jwt, c.jwtIssue = tok, now
	return tok, nil
}

func SignJWT(key *ecdsa.PrivateKey, kid, team string, iat time.Time) (string, error) {
	hdr, _ := json.Marshal(struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}{"ES256", kid})
	claims, _ := json.Marshal(struct {
		Iss string `json:"iss"`
		Iat int64  `json:"iat"`
	}{team, iat.Unix()})
	enc := base64.RawURLEncoding
	input := enc.EncodeToString(hdr) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(input))
	der, err := crypto.Signer(key).Sign(rand.Reader, digest[:], crypto.SHA256)
	if err != nil {
		return "", fmt.Errorf("pushv2: sign provider token: %w", err)
	}
	var sig struct{ R, S *big.Int }
	if rest, err := asn1.Unmarshal(der, &sig); err != nil || len(rest) != 0 {
		return "", errors.New("pushv2: provider token signature is not DER")
	}
	raw := make([]byte, 64)
	sig.R.FillBytes(raw[:32])
	sig.S.FillBytes(raw[32:])
	return input + "." + enc.EncodeToString(raw), nil
}

func (c *Client) Send(ctx context.Context, t Target) Result {
	r, reason, jwt := c.send(ctx, t, "")
	if reason == "ExpiredProviderToken" {
		r, _, _ = c.send(ctx, t, jwt)
	}
	return r
}

func (c *Client) send(ctx context.Context, t Target, refused string) (Result, string, string) {
	base, ok := c.hosts[t.Environment]
	if !ok || !ValidTokenHex(t.TokenHex) {
		return ResultGone, "BadDeviceToken", ""
	}
	jwt, err := c.providerToken(refused)
	if err != nil {
		return ResultConfig, "sign", ""
	}
	if refused != "" && jwt == refused {
		return ResultConfig, "ExpiredProviderToken", jwt
	}
	ctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/3/device/"+t.TokenHex,
		bytes.NewReader([]byte(Payload)))
	if err != nil {
		return ResultTransient, "", jwt
	}
	h := req.Header
	h["User-Agent"] = []string{""}
	h.Set("authorization", "bearer "+jwt)
	h.Set("apns-topic", c.topic)
	h.Set("apns-push-type", "background")
	h.Set("apns-priority", "5")
	h.Set("apns-expiration", strconv.FormatInt(c.now().Add(expirationWindow).Unix(), 10))
	h.Set("content-type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return ResultTransient, "", jwt
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var apnsErr struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(body, &apnsErr)
	return classify(resp.StatusCode, apnsErr.Reason), apnsErr.Reason, jwt
}

func classify(status int, reason string) Result {
	switch {
	case status == http.StatusOK:
		return ResultSent
	case status == http.StatusGone,
		status == http.StatusBadRequest && (reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic"):
		return ResultGone
	case status == http.StatusTooManyRequests:
		return ResultCooldown
	case status == http.StatusForbidden && (reason == "BadEnvironmentKeyIdInToken" || reason == "BadEnvironmentKeyInToken" ||
		reason == "BadCertificateEnvironment"):
		return ResultEnvironment
	case status == http.StatusForbidden:
		return ResultConfig
	}
	return ResultTransient
}

func ValidTokenHex(s string) bool {
	if len(s) < 64 || len(s) > 200 || len(s)%2 != 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
