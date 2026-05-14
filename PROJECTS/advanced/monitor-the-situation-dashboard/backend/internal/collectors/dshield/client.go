// ©AngelaMos | 2026
// client.go

package dshield

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	KindTopPorts     = "topports"
	KindTopIPs       = "topips"
	KindDailySummary = "dailysummary"

	defaultTopN          = 10
	defaultDShieldRate   = 2 * time.Second
	defaultDShieldBudget = 5
	defaultBreakerWindow = 60 * time.Second
)

type ClientConfig struct {
	BaseURL string
	TopN    int
}

type Client struct {
	hx   *httpx.Client
	topN int
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = "https://isc.sans.edu"
	}
	if cfg.TopN <= 0 {
		cfg.TopN = defaultTopN
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "dshield",
			BaseURL:                  cfg.BaseURL,
			Rate:                     rate.Every(defaultDShieldRate),
			Burst:                    1,
			ConsecutiveFailureBudget: defaultDShieldBudget,
			BreakerTimeout:           defaultBreakerWindow,
		}),
		topN: cfg.TopN,
	}
}

type SnapshotPayload struct {
	Kind    string
	Payload json.RawMessage
}

func (c *Client) FetchAll(ctx context.Context) ([]SnapshotPayload, error) {
	yesterday := time.Now().UTC().AddDate(0, 0, -1).Format("2006-01-02")

	endpoints := []struct {
		Kind string
		Path string
	}{
		{
			KindTopPorts,
			"/api/topports/records/" + strconv.Itoa(
				c.topN,
			) + "/" + yesterday + "?json",
		},
		{KindTopIPs, "/api/topips/?json"},
		{KindDailySummary, "/api/dailysummary/" + yesterday + "/?json"},
	}

	out := make([]SnapshotPayload, 0, len(endpoints))
	for _, ep := range endpoints {
		var raw json.RawMessage
		if err := c.hx.GetJSON(ctx, ep.Path, nil, &raw); err != nil {
			return nil, fmt.Errorf("dshield %s: %w", ep.Kind, err)
		}
		out = append(out, SnapshotPayload{Kind: ep.Kind, Payload: raw})
	}
	return out, nil
}
