// ©AngelaMos | 2026
// client.go

package iss

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	defaultISSPositionURL = "https://api.wheretheiss.at"
	defaultISSTLEURL      = "https://celestrak.org"
	pathPosition          = "/v1/satellites/25544"
	pathTLE               = "/NORAD/elements/gp.php"
	defaultISSRate        = 200 * time.Millisecond
	defaultISSBurst       = 5
	defaultISSBudget      = 5
	defaultISSBreaker     = 60 * time.Second
)

type Position struct {
	Latitude  float64   `json:"latitude"`
	Longitude float64   `json:"longitude"`
	Altitude  float64   `json:"altitude"`
	Velocity  float64   `json:"velocity"`
	Timestamp int64     `json:"timestamp"`
	FetchedAt time.Time `json:"fetched_at"`
}

type TLE struct {
	Line1     string    `json:"line1"`
	Line2     string    `json:"line2"`
	FetchedAt time.Time `json:"fetched_at"`
}

type ClientConfig struct {
	PositionBaseURL string
	TLEBaseURL      string
}

type Client struct {
	pos *httpx.Client
	tle *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.PositionBaseURL == "" {
		cfg.PositionBaseURL = defaultISSPositionURL
	}
	if cfg.TLEBaseURL == "" {
		cfg.TLEBaseURL = defaultISSTLEURL
	}
	return &Client{
		pos: httpx.New(httpx.Config{
			Name:                     "iss-position",
			BaseURL:                  cfg.PositionBaseURL,
			Rate:                     rate.Every(defaultISSRate),
			Burst:                    defaultISSBurst,
			ConsecutiveFailureBudget: defaultISSBudget,
			BreakerTimeout:           defaultISSBreaker,
		}),
		tle: httpx.New(httpx.Config{
			Name:                     "iss-tle",
			BaseURL:                  cfg.TLEBaseURL,
			Rate:                     rate.Every(time.Second),
			Burst:                    1,
			ConsecutiveFailureBudget: defaultISSBudget,
			BreakerTimeout:           defaultISSBreaker,
		}),
	}
}

func (c *Client) FetchPosition(ctx context.Context) (Position, error) {
	var p Position
	if err := c.pos.GetJSON(ctx, pathPosition, nil, &p); err != nil {
		return Position{}, fmt.Errorf("fetch iss position: %w", err)
	}
	p.FetchedAt = time.Now().UTC()
	return p, nil
}

func (c *Client) FetchTLE(ctx context.Context) (TLE, error) {
	q := map[string][]string{
		"CATNR":  {"25544"},
		"FORMAT": {"TLE"},
	}
	resp, err := c.tle.Get(ctx, pathTLE, q)
	if err != nil {
		return TLE{}, fmt.Errorf("fetch iss tle: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return TLE{}, fmt.Errorf("read iss tle body: %w", err)
	}

	lines := strings.Split(strings.TrimSpace(string(body)), "\n")
	if len(lines) < 3 {
		return TLE{}, fmt.Errorf(
			"iss tle: expected 3 lines, got %d",
			len(lines),
		)
	}
	return TLE{
		Line1:     strings.TrimRight(lines[1], " \r"),
		Line2:     strings.TrimRight(lines[2], " \r"),
		FetchedAt: time.Now().UTC(),
	}, nil
}
