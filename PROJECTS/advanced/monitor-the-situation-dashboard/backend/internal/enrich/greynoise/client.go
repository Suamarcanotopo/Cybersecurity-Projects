// ©AngelaMos | 2026
// client.go

package greynoise

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	defaultGNBaseURL    = "https://api.greynoise.io"
	pathCommunityLookup = "/v3/community/"
	greynoiseAPIHeader  = "key"
	defaultGNRate       = 2 * time.Second
	defaultGNBudget     = 3
	defaultGNBreakerWin = 5 * time.Minute
	defaultGNRequestTO  = 10 * time.Second
)

var ErrUnknownIP = errors.New("greynoise: unknown ip")

type ClientConfig struct {
	BaseURL string
	APIKey  string
}

type Client struct {
	hx *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultGNBaseURL
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "greynoise",
			BaseURL:                  cfg.BaseURL,
			APIKey:                   cfg.APIKey,
			APIKeyHeader:             greynoiseAPIHeader,
			Rate:                     rate.Every(defaultGNRate),
			Burst:                    1,
			ConsecutiveFailureBudget: defaultGNBudget,
			BreakerTimeout:           defaultGNBreakerWin,
			RequestTimeout:           defaultGNRequestTO,
		}),
	}
}

type Verdict struct {
	IP             string `json:"ip"`
	Noise          bool   `json:"noise"`
	Riot           bool   `json:"riot"`
	Classification string `json:"classification"`
	Name           string `json:"name"`
	Link           string `json:"link"`
	LastSeen       string `json:"last_seen"`
	Message        string `json:"message"`
}

func (c *Client) Lookup(ctx context.Context, ip string) (Verdict, error) {
	resp, err := c.hx.Get(ctx, pathCommunityLookup+url.PathEscape(ip), nil)
	if err != nil {
		var se *httpx.StatusError
		if errors.As(err, &se) && se.Code == http.StatusNotFound {
			return Verdict{}, ErrUnknownIP
		}
		return Verdict{}, fmt.Errorf("greynoise lookup %s: %w", ip, err)
	}
	defer resp.Body.Close()

	var v Verdict
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil {
		return Verdict{}, fmt.Errorf("greynoise decode: %w", err)
	}
	return v, nil
}
