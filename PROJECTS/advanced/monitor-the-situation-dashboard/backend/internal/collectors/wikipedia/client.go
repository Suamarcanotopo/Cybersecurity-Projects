// ©AngelaMos | 2026
// client.go

package wikipedia

import (
	"context"
	"fmt"
	"io"
	"net/url"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	defaultWikiBaseURL = "https://en.wikipedia.org"
	pathAPI            = "/w/api.php"
	defaultWikiRate    = 200 * time.Millisecond
	defaultWikiBurst   = 5
	defaultWikiBudget  = 5
	defaultWikiBreaker = 60 * time.Second
)

type ClientConfig struct {
	BaseURL string
}

type Client struct {
	hx *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultWikiBaseURL
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "wikipedia",
			BaseURL:                  cfg.BaseURL,
			Rate:                     rate.Every(defaultWikiRate),
			Burst:                    defaultWikiBurst,
			ConsecutiveFailureBudget: defaultWikiBudget,
			BreakerTimeout:           defaultWikiBreaker,
		}),
	}
}

func (c *Client) Fetch(ctx context.Context) (Response, error) {
	q := url.Values{}
	q.Set("action", "parse")
	q.Set("page", "Template:In_the_news")
	q.Set("prop", "text|revid")
	q.Set("format", "json")

	resp, err := c.hx.Get(ctx, pathAPI, q)
	if err != nil {
		return Response{}, fmt.Errorf("fetch wikipedia ITN: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return Response{}, fmt.Errorf("read wikipedia ITN body: %w", err)
	}
	return DecodeResponse(body)
}
