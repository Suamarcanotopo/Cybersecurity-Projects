// ©AngelaMos | 2026
// client.go

package usgs

import (
	"context"
	"fmt"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	defaultUSGSBaseURL = "https://earthquake.usgs.gov"
	pathQuakes2_5_day  = "/earthquakes/feed/v1.0/summary/2.5_day.geojson"
	defaultUSGSRate    = 100 * time.Millisecond
	defaultUSGSBurst   = 5
	defaultUSGSBudget  = 5
	defaultUSGSBreaker = 60 * time.Second
)

type ClientConfig struct {
	BaseURL string
}

type Client struct {
	hx *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultUSGSBaseURL
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "usgs",
			BaseURL:                  cfg.BaseURL,
			Rate:                     rate.Every(defaultUSGSRate),
			Burst:                    defaultUSGSBurst,
			ConsecutiveFailureBudget: defaultUSGSBudget,
			BreakerTimeout:           defaultUSGSBreaker,
		}),
	}
}

type Feed struct {
	Type     string    `json:"type"`
	Features []Feature `json:"features"`
}

type Feature struct {
	Type       string     `json:"type"`
	ID         string     `json:"id"`
	Properties Properties `json:"properties"`
	Geometry   Geometry   `json:"geometry"`
}

type Properties struct {
	Mag     float64 `json:"mag"`
	Place   string  `json:"place"`
	Time    int64   `json:"time"`
	Updated int64   `json:"updated"`
	Alert   string  `json:"alert"`
	Tsunami int     `json:"tsunami"`
	URL     string  `json:"url"`
	Type    string  `json:"type"`
}

func (p Properties) OccurredAt() time.Time {
	return time.UnixMilli(p.Time).UTC()
}

type Geometry struct {
	Type        string    `json:"type"`
	Coordinates []float64 `json:"coordinates"`
}

func (c *Client) Fetch(ctx context.Context) (Feed, error) {
	var feed Feed
	if err := c.hx.GetJSON(ctx, pathQuakes2_5_day, nil, &feed); err != nil {
		return Feed{}, fmt.Errorf("fetch usgs feed: %w", err)
	}
	return feed, nil
}
