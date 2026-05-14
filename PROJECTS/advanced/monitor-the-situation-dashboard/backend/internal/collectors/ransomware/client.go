// ©AngelaMos | 2026
// client.go

package ransomware

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	defaultRansomBaseURL    = "https://api.ransomware.live"
	pathRecentVictims       = "/recentvictims"
	defaultRansomRate       = time.Second
	defaultRansomBudget     = 5
	defaultRansomBreakerWin = 60 * time.Second
	idHashBytes             = 16
)

type ClientConfig struct {
	BaseURL string
}

type Client struct {
	hx *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultRansomBaseURL
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "ransomware",
			BaseURL:                  cfg.BaseURL,
			Rate:                     rate.Every(defaultRansomRate),
			Burst:                    1,
			ConsecutiveFailureBudget: defaultRansomBudget,
			BreakerTimeout:           defaultRansomBreakerWin,
		}),
	}
}

type Victim struct {
	PostTitle   string    `json:"post_title"`
	GroupName   string    `json:"group_name"`
	Discovered  time.Time `json:"discovered"`
	Country     string    `json:"country"`
	Activity    string    `json:"activity"`
	Website     string    `json:"website"`
	Description string    `json:"description"`
}

func (v Victim) ID() string {
	h := sha256.Sum256(
		[]byte(
			v.PostTitle + "|" + v.GroupName + "|" + v.Discovered.UTC().
				Format(time.RFC3339),
		),
	)
	return hex.EncodeToString(h[:idHashBytes])
}

func (c *Client) FetchRecent(ctx context.Context) ([]Victim, error) {
	var out []Victim
	if err := c.hx.GetJSON(ctx, pathRecentVictims, nil, &out); err != nil {
		return nil, fmt.Errorf("fetch recentvictims: %w", err)
	}
	return out, nil
}
