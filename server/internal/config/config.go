package config

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/BurntSushi/toml"

	"github.com/salehtl/hasala/server/internal/headroom"
	"github.com/salehtl/hasala/server/internal/invites"
	"github.com/salehtl/hasala/server/internal/mail"
)

type Config struct {
	Mode string `toml:"-"`

	Server   ServerConfig   `toml:"server"`
	Auth     AuthConfig     `toml:"auth"`
	Headroom HeadroomConfig `toml:"headroom"`
	APNs     APNsConfig     `toml:"apns"`
	Gmail    GmailConfig    `toml:"gmail"`
	Outlook  OutlookConfig  `toml:"outlook"`
	Email    EmailConfig    `toml:"email"`
	Web      WebConfig      `toml:"-"`
	Ops      OpsConfig      `toml:"-"`

	Console ConsoleConfig `toml:"-"`

	PGDSN      string `toml:"-"`
	MigrateDSN string `toml:"-"`

	Purge   PurgeArgs   `toml:"-"`
	Verify  VerifyArgs  `toml:"-"`
	Migrate MigrateArgs `toml:"-"`
}

type ServerConfig struct {
	HTTPListen        string `toml:"http_listen"`
	MetricsListen     string `toml:"metrics_listen"`
	TrustedProxy      string `toml:"trusted_proxy"`
	MinIOSBuild       int    `toml:"min_ios_build"`
	LogLevel          string `toml:"log_level"`
	LogGenerationFile string `toml:"-"`
	LogGeneration     int    `toml:"-"`
	PurgeLedgerPath   string `toml:"-"`
}

func ReadLogGeneration(path string) (int, error) {
	if path == "" {
		return 1, nil
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return 1, nil
	}
	if err != nil {
		return 0, fmt.Errorf("HASALA_LOG_GENERATION_FILE: %w", err)
	}
	text := strings.TrimSpace(string(raw))
	n, err := strconv.Atoi(text)
	if err != nil || n < 1 || strings.HasPrefix(text, "+") {
		return 0, fmt.Errorf("HASALA_LOG_GENERATION_FILE %s holds %q: want one decimal integer >= 1", path, text)
	}
	return n, nil
}

type logSeal struct {
	generation int
	database   string
}

func SettleLogGeneration(path, database string) (int, bool, error) {
	generation, err := ReadLogGeneration(path)
	if err != nil || path == "" {
		return generation, false, err
	}
	if database == "" {
		return 0, false, errors.New("HASALA_LOG_GENERATION_FILE: the database has no identity to compare")
	}
	sealPath := path + ".seal"
	seal, sealed, err := readLogSeal(sealPath)
	if err != nil {
		return 0, false, err
	}
	raised := sealed && seal.database != database && generation <= seal.generation
	wentBack := sealed && !raised && generation < seal.generation
	if raised {
		generation = seal.generation + 1
	} else if wentBack {
		generation = seal.generation
	}
	if raised || wentBack {
		if err := writeGenerationFile(path, strconv.Itoa(generation)+"\n"); err != nil {
			return 0, false, err
		}
	}
	current := logSeal{generation: generation, database: database}
	if !sealed || seal != current {
		if err := writeGenerationFile(sealPath, strconv.Itoa(generation)+" "+database+"\n"); err != nil {
			return 0, false, err
		}
	}
	return generation, raised, nil
}

func readLogSeal(path string) (logSeal, bool, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return logSeal{}, false, nil
	}
	if err != nil {
		return logSeal{}, false, fmt.Errorf("HASALA_LOG_GENERATION_FILE seal: %w", err)
	}
	fields := strings.Fields(string(raw))
	if len(fields) == 2 {
		if n, err := strconv.Atoi(fields[0]); err == nil && n >= 1 {
			return logSeal{generation: n, database: fields[1]}, true, nil
		}
	}
	return logSeal{}, false, fmt.Errorf("HASALA_LOG_GENERATION_FILE seal %s holds %q: want a generation and a database identity", path, raw)
}

func writeGenerationFile(path, body string) error {
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o660)
	if err != nil {
		return fmt.Errorf("HASALA_LOG_GENERATION_FILE: %w", err)
	}
	werr := f.Chmod(0o660)
	if werr == nil {
		_, werr = f.WriteString(body)
	}
	if werr == nil {
		werr = f.Sync()
	}
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Rename(tmp, path)
	}
	if werr != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("HASALA_LOG_GENERATION_FILE: %w", werr)
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return fmt.Errorf("HASALA_LOG_GENERATION_FILE: %w", err)
	}
	defer dir.Close()
	if err := dir.Sync(); err != nil {
		return fmt.Errorf("HASALA_LOG_GENERATION_FILE: %w", err)
	}
	return nil
}

const (
	ProxyNone       = "none"
	ProxyCloudflare = "cloudflare"
)

type AuthConfig struct {
	RPID                    string        `toml:"rp_id"`
	RPDisplayName           string        `toml:"rp_display_name"`
	RPOrigins               []string      `toml:"rp_origins"`
	SessionIdle             time.Duration `toml:"session_idle"`
	SessionMax              time.Duration `toml:"session_max"`
	InviteTTL               time.Duration `toml:"invite_ttl"`
	PasswordHashConcurrency int           `toml:"password_hash_concurrency"`
	AuthKeyFile             string        `toml:"-"`
	SaltKeyFile             string        `toml:"-"`
}

type HeadroomConfig struct {
	Path       string        `toml:"path"`
	FloorBytes int64         `toml:"floor_bytes"`
	Interval   time.Duration `toml:"interval"`
}

type APNsConfig struct {
	Enabled             bool     `toml:"enabled"`
	TeamID              string   `toml:"team_id"`
	KeyID               string   `toml:"key_id"`
	Topic               string   `toml:"topic"`
	AllowedEnvironments []string `toml:"allowed_environments"`
	KeyFile             string   `toml:"-"`
}

type GmailConfig struct {
	IOSClientID          string `toml:"ios_client_id"`
	PubSubTopic          string `toml:"pubsub_topic"`
	PubSubSubscription   string `toml:"pubsub_subscription"`
	PubSubAudience       string `toml:"pubsub_audience"`
	PubSubServiceAccount string `toml:"pubsub_service_account"`
	RouteKeyFile         string `toml:"-"`
}

func (g GmailConfig) LinkEnabled() bool { return g.IOSClientID != "" }

func (g GmailConfig) PushEnabled() bool {
	return g.PubSubTopic != "" || g.PubSubSubscription != "" || g.PubSubAudience != "" || g.PubSubServiceAccount != ""
}

type OutlookConfig struct {
	ClientID        string `toml:"client_id"`
	NotificationURL string `toml:"notification_url"`
	LifecycleURL    string `toml:"lifecycle_url"`
}

const (
	OutlookNotificationPath = "/hooks/outlook/graph"
	OutlookLifecyclePath    = "/hooks/outlook/graph/lifecycle"
)

func (o OutlookConfig) LinkEnabled() bool { return o.ClientID != "" }

func (o OutlookConfig) PushEnabled() bool { return o.NotificationURL != "" || o.LifecycleURL != "" }

type EmailConfig struct {
	CloudflareAccountID string `toml:"cloudflare_account_id"`
	FromName            string `toml:"from_name"`
	From                string `toml:"from"`
	ReplyTo             string `toml:"reply_to"`
	FreezeURL           string `toml:"freeze_url"`
	APITokenFile        string `toml:"-"`
	WebBaseURL          string `toml:"-"`
	APIBaseURL          string `toml:"-"`
}

const DefaultEmailAPIBaseURL = mail.DefaultBaseURL

func (e EmailConfig) Enabled() bool { return e.CloudflareAccountID != "" || e.APITokenFile != "" }

type WebConfig struct {
	Origins             []string
	DoneURL             string
	WaitlistMax         int64
	WaitlistPendingMax  int64
	WaitlistRetention   time.Duration
	RateWaitlist        int64
	RateBulk            int64
	LogRetention        time.Duration
	TurnstileSecretFile string   `toml:"-"`
	TurnstileRequired   bool     `toml:"-"`
	TurnstileHostnames  []string `toml:"-"`
}

type OpsConfig struct {
	NtfyURL   string
	NtfyClick string
}

func (o OpsConfig) Enabled() bool { return o.NtfyURL != "" }

type ConsoleConfig struct {
	Listen         string
	MetricsListen  string
	Host           string
	Logins         []string
	Tailnet        string
	TestFlightMode string
}

type PurgeArgs struct {
	User         string
	Confirm      string
	DryRun       bool
	ReplayLedger bool
}

type VerifyArgs struct {
	Check  string
	User   string
	Repair bool
	JSON   bool
}

type MigrateArgs struct {
	Status  bool
	Pending bool
	To      int64
}

var modeOrder = []string{"serve", "migrate", "verify", "purge-user", "invite", "account", "mailbox", "waitlist", "email",
	"console", "version"}

func Modes() []string {
	return slices.Clone(modeOrder)
}

func defaults() Config {
	return Config{
		Server: ServerConfig{
			HTTPListen:   "127.0.0.1:8443",
			TrustedProxy: ProxyNone,
			LogLevel:     "info",
		},
		Auth: AuthConfig{
			RPDisplayName:           "Hasala",
			SessionIdle:             720 * time.Hour,
			SessionMax:              2160 * time.Hour,
			InviteTTL:               336 * time.Hour,
			PasswordHashConcurrency: 1,
		},
		Headroom: HeadroomConfig{
			FloorBytes: 8_000_000_000,
			Interval:   headroom.DefaultInterval,
		},
		APNs: APNsConfig{
			Topic:               "app.hasala.ios",
			AllowedEnvironments: []string{"production", "sandbox"},
		},
		Web: WebConfig{
			DoneURL:            "https://hasala.app/joined",
			WaitlistMax:        10_000,
			WaitlistPendingMax: 2_000,
			WaitlistRetention:  4320 * time.Hour,
			RateWaitlist:       60,
			RateBulk:           120,
			LogRetention:       720 * time.Hour,
		},
		Email: EmailConfig{
			FromName:   "Hasala",
			From:       "no-reply@hasala.app",
			ReplyTo:    "support@hasala.app",
			FreezeURL:  "https://hasala.app/freeze",
			WebBaseURL: "https://hasala.app",
		},
	}
}

func LoadEnv(path string, lookup func(string) (string, bool), environ []string) (Config, error) {
	cfg := defaults()
	if path == "" {
		path, _ = lookup("HASALA_CONFIG")
	}
	if path != "" {
		meta, err := toml.DecodeFile(path, &cfg)
		if err != nil {
			return Config{}, fmt.Errorf("decode config %q: %w", path, err)
		}
		if bad := meta.Undecoded(); len(bad) > 0 {
			keys := make([]string, len(bad))
			for i, k := range bad {
				keys[i] = k.String()
			}
			return Config{}, fmt.Errorf("config %q sets unrecognized key(s) %s: secrets come only from "+
				"HASALA_*_FILE paths and are never read from TOML, and misspelled keys are refused",
				path, strings.Join(keys, ", "))
		}
	}
	if err := applyEnv(&cfg, lookup); err != nil {
		return Config{}, err
	}
	if err := cfg.validate(lookup, environ); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func applyEnv(c *Config, lookup func(string) (string, bool)) error {
	str := func(name string, dst *string) {
		if v, ok := lookup(name); ok && v != "" {
			*dst = v
		}
	}
	list := func(name string, dst *[]string) {
		if v, ok := lookup(name); ok && v != "" {
			*dst = splitCSV(v)
		}
	}
	var errs []error
	dur := func(name string, dst *time.Duration) {
		if v, ok := lookup(name); ok && v != "" {
			d, err := time.ParseDuration(v)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s %q is not a duration: %w", name, v, err))
				return
			}
			*dst = d
		}
	}
	integer := func(name string, dst *int64) {
		if v, ok := lookup(name); ok && v != "" {
			n, err := strconv.ParseInt(v, 10, 64)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s %q is not an integer: %w", name, v, err))
				return
			}
			*dst = n
		}
	}
	boolean := func(name string, dst *bool) {
		if v, ok := lookup(name); ok && v != "" {
			b, err := strconv.ParseBool(v)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s %q is not a boolean: %w", name, v, err))
				return
			}
			*dst = b
		}
	}

	str("HASALA_PG_DSN", &c.PGDSN)
	str("HASALA_MIGRATE_DSN", &c.MigrateDSN)

	str("HASALA_HTTP_LISTEN", &c.Server.HTTPListen)
	str("HASALA_METRICS_LISTEN", &c.Server.MetricsListen)
	str("HASALA_TRUSTED_PROXY", &c.Server.TrustedProxy)
	var minBuild = int64(c.Server.MinIOSBuild)
	integer("HASALA_MIN_IOS_BUILD", &minBuild)
	c.Server.MinIOSBuild = int(minBuild)
	str("HASALA_LOG_LEVEL", &c.Server.LogLevel)
	str("HASALA_LOG_GENERATION_FILE", &c.Server.LogGenerationFile)
	str("HASALA_PURGE_LEDGER_PATH", &c.Server.PurgeLedgerPath)

	str("HASALA_RP_ID", &c.Auth.RPID)
	str("HASALA_RP_DISPLAY_NAME", &c.Auth.RPDisplayName)
	list("HASALA_RP_ORIGINS", &c.Auth.RPOrigins)
	dur("HASALA_SESSION_IDLE", &c.Auth.SessionIdle)
	dur("HASALA_SESSION_MAX", &c.Auth.SessionMax)
	dur("HASALA_INVITE_TTL", &c.Auth.InviteTTL)
	var conc = int64(c.Auth.PasswordHashConcurrency)
	integer("HASALA_PASSWORD_HASH_CONCURRENCY", &conc)
	c.Auth.PasswordHashConcurrency = int(conc)
	str("HASALA_AUTH_KEY_FILE", &c.Auth.AuthKeyFile)
	str("HASALA_SALT_KEY_FILE", &c.Auth.SaltKeyFile)

	str("HASALA_HEADROOM_PATH", &c.Headroom.Path)
	integer("HASALA_HEADROOM_FLOOR_BYTES", &c.Headroom.FloorBytes)
	dur("HASALA_HEADROOM_INTERVAL", &c.Headroom.Interval)

	boolean("HASALA_APNS_ENABLED", &c.APNs.Enabled)
	str("HASALA_APNS_TEAM_ID", &c.APNs.TeamID)
	str("HASALA_APNS_KEY_ID", &c.APNs.KeyID)
	str("HASALA_APNS_KEY_FILE", &c.APNs.KeyFile)
	str("HASALA_APNS_TOPIC", &c.APNs.Topic)
	list("HASALA_APNS_ENVIRONMENTS", &c.APNs.AllowedEnvironments)

	str("HASALA_GOOGLE_IOS_CLIENT_ID", &c.Gmail.IOSClientID)
	str("HASALA_GMAIL_PUBSUB_TOPIC", &c.Gmail.PubSubTopic)
	str("HASALA_GMAIL_PUBSUB_SUBSCRIPTION", &c.Gmail.PubSubSubscription)
	str("HASALA_GMAIL_PUBSUB_AUDIENCE", &c.Gmail.PubSubAudience)
	str("HASALA_GMAIL_PUBSUB_SA_EMAIL", &c.Gmail.PubSubServiceAccount)
	str("HASALA_MAILBOX_ROUTE_KEY_FILE", &c.Gmail.RouteKeyFile)

	str("HASALA_OUTLOOK_CLIENT_ID", &c.Outlook.ClientID)
	str("HASALA_OUTLOOK_NOTIFICATION_URL", &c.Outlook.NotificationURL)
	str("HASALA_OUTLOOK_LIFECYCLE_URL", &c.Outlook.LifecycleURL)

	str("HASALA_EMAIL_CF_ACCOUNT_ID", &c.Email.CloudflareAccountID)
	str("HASALA_EMAIL_FROM_NAME", &c.Email.FromName)
	str("HASALA_EMAIL_FROM", &c.Email.From)
	str("HASALA_EMAIL_REPLY_TO", &c.Email.ReplyTo)
	str("HASALA_FREEZE_URL", &c.Email.FreezeURL)
	str("HASALA_EMAIL_API_TOKEN_FILE", &c.Email.APITokenFile)
	str("HASALA_WEB_BASE_URL", &c.Email.WebBaseURL)
	str("HASALA_EMAIL_API_BASE_URL", &c.Email.APIBaseURL)
	list("HASALA_WEB_ORIGINS", &c.Web.Origins)
	str("HASALA_WEB_WAITLIST_DONE_URL", &c.Web.DoneURL)
	integer("HASALA_WAITLIST_MAX", &c.Web.WaitlistMax)
	integer("HASALA_WAITLIST_PENDING_MAX", &c.Web.WaitlistPendingMax)
	dur("HASALA_WAITLIST_RETENTION", &c.Web.WaitlistRetention)
	integer("HASALA_EMAIL_RATE_WAITLIST", &c.Web.RateWaitlist)
	integer("HASALA_EMAIL_RATE_BULK", &c.Web.RateBulk)
	dur("HASALA_EMAIL_LOG_RETENTION", &c.Web.LogRetention)
	str("HASALA_TURNSTILE_SECRET_FILE", &c.Web.TurnstileSecretFile)
	boolean("HASALA_TURNSTILE_REQUIRED", &c.Web.TurnstileRequired)
	list("HASALA_TURNSTILE_HOSTNAMES", &c.Web.TurnstileHostnames)
	str("HASALA_OPS_NTFY_URL", &c.Ops.NtfyURL)
	str("HASALA_OPS_NTFY_CLICK", &c.Ops.NtfyClick)

	str("HASALA_CONSOLE_LISTEN", &c.Console.Listen)
	str("HASALA_CONSOLE_METRICS_LISTEN", &c.Console.MetricsListen)
	str("HASALA_CONSOLE_HOST", &c.Console.Host)
	list("HASALA_CONSOLE_LOGINS", &c.Console.Logins)
	str("HASALA_CONSOLE_TAILNET", &c.Console.Tailnet)
	str("HASALA_TESTFLIGHT_MODE", &c.Console.TestFlightMode)
	return errors.Join(errs...)
}

func (c Config) validate(lookup func(string) (string, bool), environ []string) error {
	switch c.Server.TrustedProxy {
	case ProxyNone, ProxyCloudflare:
	default:
		return fmt.Errorf("server.trusted_proxy is %q (HASALA_TRUSTED_PROXY): want %q or %q",
			c.Server.TrustedProxy, ProxyNone, ProxyCloudflare)
	}
	prod := c.Server.TrustedProxy == ProxyCloudflare
	if !IsLoopbackListen(c.Server.HTTPListen) {
		return fmt.Errorf("server.http_listen is %q (HASALA_HTTP_LISTEN): it must be a loopback "+
			"host:port; hasalad serves plain HTTP only and is reached through the tunnel", c.Server.HTTPListen)
	}
	if c.Server.MetricsListen != "" {
		if !IsLoopbackListen(c.Server.MetricsListen) {
			return fmt.Errorf("server.metrics_listen is %q (HASALA_METRICS_LISTEN): it must be loopback",
				c.Server.MetricsListen)
		}
		if samePort(c.Server.MetricsListen, c.Server.HTTPListen) {
			return fmt.Errorf("server.metrics_listen and server.http_listen must use different ports")
		}
	}
	if c.Server.MinIOSBuild < 0 {
		return fmt.Errorf("server.min_ios_build must not be negative")
	}
	switch c.Server.LogLevel {
	case "info", "warn", "error":
	case "debug":
		if prod {
			return errors.New("server.log_level debug is refused with trusted_proxy = cloudflare")
		}
	default:
		return fmt.Errorf("server.log_level is %q: want debug, info, warn or error", c.Server.LogLevel)
	}
	if err := c.validateAuth(prod); err != nil {
		return err
	}
	if err := c.validateHeadroom(); err != nil {
		return err
	}
	if err := c.validateAPNs(); err != nil {
		return err
	}
	if err := c.validateWeb(); err != nil {
		return err
	}
	if err := c.validateGmail(); err != nil {
		return err
	}
	if err := c.validateOutlook(); err != nil {
		return err
	}
	if err := c.validateOps(); err != nil {
		return err
	}
	if err := c.validateEmail(prod); err != nil {
		return err
	}
	credDir, _ := lookup("CREDENTIALS_DIRECTORY")
	for name, path := range map[string]string{
		"HASALA_AUTH_KEY_FILE":          c.Auth.AuthKeyFile,
		"HASALA_SALT_KEY_FILE":          c.Auth.SaltKeyFile,
		"HASALA_APNS_KEY_FILE":          c.APNs.KeyFile,
		"HASALA_MAILBOX_ROUTE_KEY_FILE": c.Gmail.RouteKeyFile,
		"HASALA_EMAIL_API_TOKEN_FILE":   c.Email.APITokenFile,
		"HASALA_TURNSTILE_SECRET_FILE":  c.Web.TurnstileSecretFile,
	} {
		if path == "" {
			continue
		}
		check := CheckSecretFile
		if InCredentialsDirectory(path, credDir) {
			check = CheckCredentialFile
		}
		if err := check(path); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	if prod {
		if err := refuseRawSecrets(c, lookup, environ); err != nil {
			return err
		}
	}
	return nil
}

func (c Config) validateAuth(prod bool) error {
	a := c.Auth
	if a.RPID != "" || len(a.RPOrigins) > 0 {
		if a.RPID == "" {
			return errors.New("auth.rp_origins is set but auth.rp_id is empty (HASALA_RP_ID)")
		}
		if strings.ContainsAny(a.RPID, "/:") {
			return fmt.Errorf("auth.rp_id is %q: it must be a bare domain with no scheme and no port", a.RPID)
		}
		if a.RPID == "localhost" && prod {
			return errors.New("auth.rp_id localhost is allowed only with trusted_proxy = none")
		}
		if len(a.RPOrigins) == 0 {
			return errors.New("auth.rp_id is set but auth.rp_origins is empty (HASALA_RP_ORIGINS)")
		}
		for _, o := range a.RPOrigins {
			u, err := url.Parse(o)
			if err != nil || u.Scheme == "" || u.Host == "" {
				return fmt.Errorf("auth.rp_origins entry %q is not an absolute origin (\"https://hasala.app\")", o)
			}
			if prod && u.Scheme != "https" {
				return fmt.Errorf("auth.rp_origins entry %q must be https with trusted_proxy = cloudflare", o)
			}
		}
	}
	if a.SessionIdle <= 0 {
		return errors.New("auth.session_idle must be positive (HASALA_SESSION_IDLE)")
	}
	if a.SessionMax < a.SessionIdle {
		return fmt.Errorf("auth.session_max (%s) must be at least auth.session_idle (%s)", a.SessionMax, a.SessionIdle)
	}
	if err := invites.CheckTTL(a.InviteTTL); err != nil {
		return fmt.Errorf("auth.invite_ttl (HASALA_INVITE_TTL): %w", err)
	}
	if a.PasswordHashConcurrency < 1 || a.PasswordHashConcurrency > 8 {
		return fmt.Errorf("auth.password_hash_concurrency is %d: want 1–8", a.PasswordHashConcurrency)
	}
	return nil
}

func (c Config) validateHeadroom() error {
	if c.Headroom.FloorBytes <= 0 {
		return fmt.Errorf("headroom.floor_bytes is %d (HASALA_HEADROOM_FLOOR_BYTES): a zero floor is a fuse that never trips",
			c.Headroom.FloorBytes)
	}
	if c.Headroom.Interval <= 0 {
		return fmt.Errorf("headroom.interval is %v (HASALA_HEADROOM_INTERVAL): it must be positive", c.Headroom.Interval)
	}
	return nil
}

var appleID10 = regexp.MustCompile(`^[A-Z0-9]{10}$`)

func (c Config) validateAPNs() error {
	a := c.APNs
	for _, e := range a.AllowedEnvironments {
		if e != "production" && e != "sandbox" {
			return fmt.Errorf("apns.allowed_environments entry %q: want production or sandbox", e)
		}
	}
	if !a.Enabled {
		return nil
	}
	switch {
	case !appleID10.MatchString(a.TeamID):
		return fmt.Errorf("apns.enabled needs apns.team_id (HASALA_APNS_TEAM_ID), 10 characters")
	case !appleID10.MatchString(a.KeyID):
		return fmt.Errorf("apns.enabled needs apns.key_id (HASALA_APNS_KEY_ID), 10 characters")
	case a.KeyFile == "":
		return errors.New("apns.enabled needs HASALA_APNS_KEY_FILE")
	case a.Topic == "":
		return errors.New("apns.topic must not be empty")
	case len(a.AllowedEnvironments) == 0:
		return errors.New("apns.allowed_environments must not be empty")
	}
	return nil
}

func (c Config) validateGmail() error {
	g := c.Gmail
	missing := func(group map[string]string) string {
		var out []string
		for name, v := range group {
			if v == "" {
				out = append(out, name)
			}
		}
		sort.Strings(out)
		return strings.Join(out, ", ")
	}
	if g.LinkEnabled() || (g.RouteKeyFile != "" && !c.Outlook.LinkEnabled()) {
		if m := missing(map[string]string{
			"gmail.ios_client_id (HASALA_GOOGLE_IOS_CLIENT_ID)": g.IOSClientID,
			"HASALA_MAILBOX_ROUTE_KEY_FILE":                     g.RouteKeyFile,
		}); m != "" {
			return fmt.Errorf("the [gmail] mailbox link needs gmail.ios_client_id and HASALA_MAILBOX_ROUTE_KEY_FILE together; missing: %s", m)
		}
	}
	if g.PushEnabled() {
		if m := missing(map[string]string{
			"gmail.pubsub_topic (HASALA_GMAIL_PUBSUB_TOPIC)":               g.PubSubTopic,
			"gmail.pubsub_subscription (HASALA_GMAIL_PUBSUB_SUBSCRIPTION)": g.PubSubSubscription,
			"gmail.pubsub_audience (HASALA_GMAIL_PUBSUB_AUDIENCE)":         g.PubSubAudience,
			"gmail.pubsub_service_account (HASALA_GMAIL_PUBSUB_SA_EMAIL)":  g.PubSubServiceAccount,
		}); m != "" {
			return fmt.Errorf("the [gmail] Pub/Sub push settings are all or nothing; missing: %s", m)
		}
		if !g.LinkEnabled() {
			return errors.New("the [gmail] Pub/Sub push needs the mailbox link: set gmail.ios_client_id " +
				"(HASALA_GOOGLE_IOS_CLIENT_ID) and HASALA_MAILBOX_ROUTE_KEY_FILE too")
		}
	}
	if !g.LinkEnabled() {
		return nil
	}
	if !strings.HasSuffix(g.IOSClientID, ".apps.googleusercontent.com") {
		return fmt.Errorf("gmail.ios_client_id %q is not a Google client id", g.IOSClientID)
	}
	if !g.PushEnabled() {
		return nil
	}
	if !strings.HasPrefix(g.PubSubTopic, "projects/") || !strings.Contains(g.PubSubTopic, "/topics/") {
		return fmt.Errorf("gmail.pubsub_topic %q: want projects/<P>/topics/<t>", g.PubSubTopic)
	}
	if !strings.HasPrefix(g.PubSubSubscription, "projects/") || !strings.Contains(g.PubSubSubscription, "/subscriptions/") {
		return fmt.Errorf("gmail.pubsub_subscription %q: want projects/<P>/subscriptions/<s>", g.PubSubSubscription)
	}
	if u, err := url.Parse(g.PubSubAudience); err != nil || u.Scheme != "https" || u.Host == "" {
		return fmt.Errorf("gmail.pubsub_audience %q: want the https URL of the hook", g.PubSubAudience)
	}
	if !isServiceAccountEmail(g.PubSubServiceAccount) {
		return fmt.Errorf("gmail.pubsub_service_account %q: want <name>@<P>.iam.gserviceaccount.com", g.PubSubServiceAccount)
	}
	return nil
}

var uuidShape = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func (c Config) validateOutlook() error {
	o := c.Outlook
	if o.PushEnabled() {
		switch {
		case o.NotificationURL == "" || o.LifecycleURL == "":
			return errors.New("the [outlook] push needs outlook.notification_url (HASALA_OUTLOOK_NOTIFICATION_URL) " +
				"and outlook.lifecycle_url (HASALA_OUTLOOK_LIFECYCLE_URL) together")
		case !o.LinkEnabled():
			return errors.New("the [outlook] push needs the mailbox link: set outlook.client_id (HASALA_OUTLOOK_CLIENT_ID) " +
				"and HASALA_MAILBOX_ROUTE_KEY_FILE too")
		}
	}
	if !o.LinkEnabled() {
		return nil
	}
	if c.Gmail.RouteKeyFile == "" {
		return errors.New("the [outlook] mailbox link needs HASALA_MAILBOX_ROUTE_KEY_FILE too")
	}
	if !uuidShape.MatchString(o.ClientID) {
		return fmt.Errorf("outlook.client_id %q is not an application (client) id in lower case", o.ClientID)
	}
	if !o.PushEnabled() {
		return nil
	}
	for _, u := range []struct{ name, v, path string }{
		{"outlook.notification_url", o.NotificationURL, OutlookNotificationPath},
		{"outlook.lifecycle_url", o.LifecycleURL, OutlookLifecyclePath},
	} {
		p, err := url.Parse(u.v)
		if err != nil || p.Scheme != "https" || p.Host == "" || p.User != nil || p.Path != u.path ||
			p.RawQuery != "" || p.ForceQuery || p.Fragment != "" {
			return fmt.Errorf("%s %q: want https://<host>%s", u.name, u.v, u.path)
		}
	}
	if a, b := hostOf(o.NotificationURL), hostOf(o.LifecycleURL); a != b {
		return fmt.Errorf("outlook.notification_url and outlook.lifecycle_url name different hosts (%s, %s)", a, b)
	}
	return nil
}

func (c Config) validateOps() error {
	o := c.Ops
	if !o.Enabled() {
		if o.NtfyClick != "" {
			return errors.New("HASALA_OPS_NTFY_CLICK needs HASALA_OPS_NTFY_URL")
		}
		return nil
	}
	u, err := url.Parse(o.NtfyURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil ||
		u.Path == "" || u.Path == "/" || u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("HASALA_OPS_NTFY_URL %q: want http(s)://<host>/<topic>, with no credentials, query or fragment", o.NtfyURL)
	}
	if o.NtfyClick != "" {
		if u, err := url.Parse(o.NtfyClick); err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
			return fmt.Errorf("HASALA_OPS_NTFY_CLICK %q: want an https URL", o.NtfyClick)
		}
	}
	return nil
}

func hostOf(raw string) string {
	u, _ := url.Parse(raw)
	return u.Host
}

func isServiceAccountEmail(s string) bool {
	const suffix = ".iam.gserviceaccount.com"
	name, domain, ok := strings.Cut(s, "@")
	return ok && name != "" && !strings.ContainsAny(s, " \t\r\n") && !strings.Contains(domain, "@") &&
		len(domain) > len(suffix) && strings.HasSuffix(domain, suffix)
}

func (c Config) validateWeb() error {
	w := c.Web
	for _, o := range w.Origins {
		u, err := url.Parse(o)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("HASALA_WEB_ORIGINS entry %q: want an https origin with no path", o)
		}
	}
	if u, err := url.Parse(w.DoneURL); err != nil || u.Scheme != "https" || u.Host != "hasala.app" || u.RawQuery != "" {
		return fmt.Errorf("HASALA_WEB_WAITLIST_DONE_URL is %q: it must be an https URL on hasala.app", w.DoneURL)
	}
	switch {
	case w.WaitlistMax < 1 || w.WaitlistPendingMax < 1:
		return errors.New("HASALA_WAITLIST_MAX and HASALA_WAITLIST_PENDING_MAX must be positive")
	case w.WaitlistRetention < 24*time.Hour:
		return errors.New("HASALA_WAITLIST_RETENTION must be at least 24h")
	case w.RateWaitlist < 1 || w.RateBulk < 1:
		return errors.New("HASALA_EMAIL_RATE_WAITLIST and HASALA_EMAIL_RATE_BULK must be positive")
	case w.LogRetention < 168*time.Hour || w.LogRetention > 2160*time.Hour:
		return errors.New("HASALA_EMAIL_LOG_RETENTION must be between 168h and 2160h")
	case w.TurnstileRequired && w.TurnstileSecretFile == "":
		return errors.New("HASALA_TURNSTILE_REQUIRED is true but HASALA_TURNSTILE_SECRET_FILE is not set")
	}
	for _, h := range w.TurnstileHostnames {
		if h == "" || strings.ToLower(h) != h || strings.ContainsAny(h, "/:@ ") {
			return fmt.Errorf("HASALA_TURNSTILE_HOSTNAMES entry %q: want a lowercase host name", h)
		}
	}
	return nil
}

var otherEnvironment = []string{"HASALA_CONFIG", "HASALA_ADMIN_ACTOR"}

func UnknownEnvironment(environ []string) []string {
	known := map[string]bool{}
	for _, n := range otherEnvironment {
		known[n] = true
	}
	var probe Config
	_ = applyEnv(&probe, func(name string) (string, bool) {
		known[name] = true
		return "", false
	})
	var unknown []string
	for _, kv := range environ {
		name, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(name, "HASALA_") && !known[name] {
			known[name] = true
			unknown = append(unknown, name)
		}
	}
	sort.Strings(unknown)
	return unknown
}

var cfAccountID = regexp.MustCompile(`^[0-9a-f]{32}$`)

func (c Config) validateEmail(prod bool) error {
	e := c.Email
	for name, addr := range map[string]string{"email.from": e.From, "email.reply_to": e.ReplyTo} {
		if !strings.HasSuffix(addr, "@hasala.app") || strings.ContainsAny(addr, " <>\"\r\n,;") ||
			strings.ToLower(addr) != addr {
			return fmt.Errorf("%s is %q: it must be a lowercase address at hasala.app", name, addr)
		}
	}
	if e.FromName == "" || strings.ContainsAny(e.FromName, "<>\"\r\n@") {
		return fmt.Errorf("email.from_name is %q: a plain display name is required", e.FromName)
	}
	for name, raw := range map[string]string{"email.freeze_url": e.FreezeURL, "HASALA_WEB_BASE_URL": e.WebBaseURL} {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.Host != "hasala.app" || u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("%s is %q: it must be an https URL on hasala.app with no query or fragment", name, raw)
		}
	}
	if e.APIBaseURL != "" {
		u, err := url.Parse(e.APIBaseURL)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil ||
			u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("HASALA_EMAIL_API_BASE_URL is %q: it must be an http(s) URL with no query or fragment",
				e.APIBaseURL)
		}
		if prod && e.APIBaseURL != DefaultEmailAPIBaseURL {
			return fmt.Errorf("HASALA_EMAIL_API_BASE_URL is %q: with trusted_proxy = cloudflare email goes only to %s",
				e.APIBaseURL, DefaultEmailAPIBaseURL)
		}
	}
	if e.Enabled() {
		if !cfAccountID.MatchString(e.CloudflareAccountID) {
			return errors.New("the [email] group is all or nothing: email.cloudflare_account_id " +
				"(HASALA_EMAIL_CF_ACCOUNT_ID) must be 32 lowercase hex characters")
		}
		if e.APITokenFile == "" {
			return errors.New("the [email] group is all or nothing: HASALA_EMAIL_API_TOKEN_FILE is missing")
		}
	} else if prod {
		return errors.New("the [email] group is required with trusted_proxy = cloudflare " +
			"(HASALA_EMAIL_CF_ACCOUNT_ID and HASALA_EMAIL_API_TOKEN_FILE)")
	}
	return nil
}

var rawSecretName = regexp.MustCompile(`^HASALA_[A-Z0-9_]*_(KEY|TOKEN|SECRET)$`)

func refuseRawSecrets(c Config, lookup func(string) (string, bool), environ []string) error {
	for _, dsn := range []struct{ name, v string }{{"HASALA_PG_DSN", c.PGDSN}, {"HASALA_MIGRATE_DSN", c.MigrateDSN}} {
		if strings.Contains(strings.ToLower(dsn.v), "password") || dsnURLHasPassword(dsn.v) {
			return fmt.Errorf("%s carries a password; with trusted_proxy = cloudflare the database "+
				"is reached by peer authentication only", dsn.name)
		}
	}
	if v, ok := lookup("PGPASSWORD"); ok && v != "" {
		return errors.New("PGPASSWORD is set; with trusted_proxy = cloudflare the database " +
			"is reached by peer authentication only")
	}
	for _, kv := range environ {
		name, _, _ := strings.Cut(kv, "=")
		if rawSecretName.MatchString(name) {
			if v, ok := lookup(name); ok && v != "" {
				return fmt.Errorf("%s is set as a raw value; with trusted_proxy = cloudflare secrets "+
					"come only from %s_FILE paths", name, name)
			}
		}
	}
	return nil
}

func dsnURLHasPassword(dsn string) bool {
	rest, ok := strings.CutPrefix(dsn, "postgres://")
	if !ok {
		rest, ok = strings.CutPrefix(dsn, "postgresql://")
	}
	if !ok {
		return false
	}
	authority, _, _ := strings.Cut(rest, "/")
	at := strings.LastIndex(authority, "@")
	return at >= 0 && strings.Contains(authority[:at], ":")
}

func (c Config) ValidateFor(mode string) error {
	switch mode {
	case "version":
		return nil
	case "migrate":
		if c.MigrateDSN == "" && !(c.Migrate.Pending && c.PGDSN != "") {
			return errors.New("migrate needs HASALA_MIGRATE_DSN (it never falls back to HASALA_PG_DSN)")
		}
		return nil
	}
	if c.PGDSN == "" {
		return errors.New("HASALA_PG_DSN is required")
	}
	if p := c.Server.PurgeLedgerPath; p != "" && !filepath.IsAbs(p) {
		return fmt.Errorf("HASALA_PURGE_LEDGER_PATH %q is not an absolute path", p)
	}
	switch mode {
	case "purge-user":
		if c.Purge.ReplayLedger && c.Server.PurgeLedgerPath == "" {
			return errors.New("purge-user --replay-ledger needs HASALA_PURGE_LEDGER_PATH")
		}
	case "serve":
		if c.Auth.RPID == "" {
			return errors.New("serve needs auth.rp_id (HASALA_RP_ID) and auth.rp_origins (HASALA_RP_ORIGINS)")
		}
		if c.Headroom.Path == "" {
			return errors.New("serve needs headroom.path (HASALA_HEADROOM_PATH): the filesystem the disk fuse samples")
		}
		if c.Server.TrustedProxy == ProxyCloudflare && (c.Auth.AuthKeyFile == "" || c.Auth.SaltKeyFile == "") {
			return errors.New("serve needs HASALA_AUTH_KEY_FILE and HASALA_SALT_KEY_FILE with trusted_proxy = cloudflare")
		}
		if c.Server.TrustedProxy == ProxyCloudflare && c.Server.PurgeLedgerPath == "" {
			return errors.New("serve needs HASALA_PURGE_LEDGER_PATH with trusted_proxy = cloudflare")
		}
	case "console":
		return c.validateConsole()
	}
	return nil
}

func CheckServeEnvironment(env []string) error {
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(name, "HASALA_CONSOLE_") || strings.HasPrefix(name, "HASALA_ASC_") ||
			name == "HASALA_TESTFLIGHT_MODE" {
			return fmt.Errorf("serve refuses to start with %s set: it belongs to the operator console", name)
		}
	}
	return nil
}

func CheckConsoleEnvironment(env []string) error {
	refused := map[string]bool{
		"HASALA_TURNSTILE_SECRET_FILE": true, "HASALA_AUTH_KEY_FILE": true, "HASALA_APNS_KEY_FILE": true,
		"HASALA_MAILBOX_ROUTE_KEY_FILE": true, "HASALA_EMAIL_API_TOKEN_FILE": true, "HASALA_SALT_KEY_FILE": true,
	}
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if refused[name] {
			return fmt.Errorf("console refuses to start with %s set: it is a secret of serve", name)
		}
	}
	return nil
}

func (c Config) validateConsole() error {
	k := c.Console
	if !isLiteralLoopback(k.Listen) {
		return fmt.Errorf("HASALA_CONSOLE_LISTEN is %q: it must be a literal loopback IP:port (127.0.0.1 or ::1)", k.Listen)
	}
	for _, other := range []string{c.Server.HTTPListen, c.Server.MetricsListen, k.MetricsListen} {
		if other != "" && samePort(k.Listen, other) {
			return fmt.Errorf("HASALA_CONSOLE_LISTEN %q shares a port with %q", k.Listen, other)
		}
	}
	if k.MetricsListen != "" && !isLiteralLoopback(k.MetricsListen) {
		return fmt.Errorf("HASALA_CONSOLE_METRICS_LISTEN is %q: it must be a literal loopback IP:port", k.MetricsListen)
	}
	if len(k.Logins) == 0 {
		return errors.New("HASALA_CONSOLE_LOGINS must list at least one login")
	}
	if k.Host == "" {
		return errors.New("HASALA_CONSOLE_HOST is required")
	}
	if c.Auth.RPID != "" && (k.Host == c.Auth.RPID || strings.HasSuffix(k.Host, "."+c.Auth.RPID)) {
		return fmt.Errorf("HASALA_CONSOLE_HOST %q is under the RP ID: the console never lives on a %s name", k.Host, c.Auth.RPID)
	}
	if k.TestFlightMode != "external" && k.TestFlightMode != "manual" {
		return fmt.Errorf("HASALA_TESTFLIGHT_MODE is %q: want external or manual", k.TestFlightMode)
	}
	return nil
}

func CheckSecretFile(path string) error {
	perm, err := regularFilePerm(path)
	if err != nil {
		return err
	}
	if perm&0o077 != 0 {
		return fmt.Errorf("secret file %s has mode %v: it must grant no group or other permission", path, perm)
	}
	return nil
}

func regularFilePerm(path string) (fs.FileMode, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return 0, fmt.Errorf("secret file: %w", err)
	}
	if !fi.Mode().IsRegular() {
		return 0, fmt.Errorf("secret file %s is not a regular file", path)
	}
	return fi.Mode().Perm(), nil
}

func InCredentialsDirectory(path, credDir string) bool {
	if credDir == "" || !filepath.IsAbs(credDir) {
		return false
	}
	return filepath.Dir(filepath.Clean(path)) == filepath.Clean(credDir)
}

func CheckCredentialFile(path string) error {
	perm, err := regularFilePerm(path)
	if err != nil {
		return err
	}
	if perm&0o027 != 0 {
		return fmt.Errorf("credential file %s has mode %v: it must grant no write or other permission", path, perm)
	}
	return nil
}

func IsLoopbackListen(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil || host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func isLiteralLoopback(addr string) bool {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || port == "" {
		return false
	}
	return host == "127.0.0.1" || host == "::1"
}

func samePort(a, b string) bool {
	_, pa, errA := net.SplitHostPort(a)
	_, pb, errB := net.SplitHostPort(b)
	return errA == nil && errB == nil && pa == pb
}

func splitCSV(v string) []string {
	fields := strings.Split(v, ",")
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}
