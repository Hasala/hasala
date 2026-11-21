package opsnotify

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const Timeout = 10 * time.Second

type Notifier struct {
	URL    string
	Click  string
	Client *http.Client
}

func New(url, click string) *Notifier {
	return &Notifier{URL: url, Click: click, Client: &http.Client{Timeout: Timeout}}
}

func (n *Notifier) Post(ctx context.Context, title, message, tags string) error {
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, n.URL, strings.NewReader(message))
	if err != nil {
		return fmt.Errorf("opsnotify: %w", err)
	}
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	req.Header.Set("Title", title)
	if tags != "" {
		req.Header.Set("Tags", tags)
	}
	if n.Click != "" {
		req.Header.Set("Click", n.Click)
	}
	resp, err := n.Client.Do(req)
	if err != nil {
		return fmt.Errorf("opsnotify: %w", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("opsnotify: ntfy answered %d", resp.StatusCode)
	}
	return nil
}
