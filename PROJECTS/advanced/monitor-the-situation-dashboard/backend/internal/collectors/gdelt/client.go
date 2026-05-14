// ©AngelaMos | 2026
// client.go

package gdelt

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	defaultGDELTBaseURL = "https://api.gdeltproject.org"
	pathDoc             = "/api/v2/doc/doc"
	defaultGDELTRate    = 500 * time.Millisecond
	defaultGDELTBurst   = 2
	defaultGDELTBudget  = 5
	defaultGDELTBreaker = 60 * time.Second

	gdeltDateFormat = "20060102T150405Z"
)

var DefaultThemes = []string{
	"NATURAL_DISASTER",
	"ARMEDCONFLICT",
	"DISEASE_OUTBREAK",
	"ECON_BANKRUPTCY",
	"TERROR",
}

type ClientConfig struct {
	BaseURL string
}

type Client struct {
	hx *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultGDELTBaseURL
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "gdelt",
			BaseURL:                  cfg.BaseURL,
			Rate:                     rate.Every(defaultGDELTRate),
			Burst:                    defaultGDELTBurst,
			ConsecutiveFailureBudget: defaultGDELTBudget,
			BreakerTimeout:           defaultGDELTBreaker,
		}),
	}
}

type ThemeBucket struct {
	Theme string
	Time  time.Time
	Count int
}

type rawTimeline struct {
	Timeline []struct {
		Data []struct {
			Date  string  `json:"date"`
			Value float64 `json:"value"`
		} `json:"data"`
	} `json:"timeline"`
}

func (c *Client) FetchTheme(
	ctx context.Context,
	theme string,
) ([]ThemeBucket, error) {
	q := url.Values{}
	q.Set("query", "theme:"+theme)
	q.Set("mode", "timelinevol")
	q.Set("TIMELINESMOOTH", "5")
	q.Set("format", "json")
	q.Set("timespan", "1d")

	resp, err := c.hx.Get(ctx, pathDoc, q)
	if err != nil {
		return nil, fmt.Errorf("fetch gdelt theme %s: %w", theme, err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read gdelt theme %s body: %w", theme, err)
	}

	var raw rawTimeline
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("decode gdelt theme %s: %w", theme, err)
	}
	if len(raw.Timeline) == 0 {
		return nil, nil
	}
	out := make([]ThemeBucket, 0, len(raw.Timeline[0].Data))
	for _, d := range raw.Timeline[0].Data {
		ts, err := time.Parse(gdeltDateFormat, d.Date)
		if err != nil {
			continue
		}
		out = append(out, ThemeBucket{
			Theme: theme,
			Time:  ts.UTC(),
			Count: int(d.Value),
		})
	}
	return out, nil
}
