// ©AngelaMos | 2026
// epss_client.go

package cve

import (
	"context"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	epssBatchSize         = 100
	defaultEPSSBaseURL    = "https://api.first.org"
	pathEPSS              = "/data/v1/epss"
	defaultEPSSRate       = 500 * time.Millisecond
	defaultEPSSBurst      = 5
	defaultEPSSBudget     = 5
	defaultEPSSBreakerWin = 60 * time.Second
)

type EPSSClientConfig struct {
	BaseURL string
}

type EPSSClient struct {
	hx *httpx.Client
}

func NewEPSSClient(cfg EPSSClientConfig) *EPSSClient {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultEPSSBaseURL
	}
	return &EPSSClient{
		hx: httpx.New(httpx.Config{
			Name:                     "epss",
			BaseURL:                  cfg.BaseURL,
			Rate:                     rate.Every(defaultEPSSRate),
			Burst:                    defaultEPSSBurst,
			ConsecutiveFailureBudget: defaultEPSSBudget,
			BreakerTimeout:           defaultEPSSBreakerWin,
		}),
	}
}

type EPSSScore struct {
	CveID      string  `json:"cve"`
	Score      float64 `json:"-"`
	Percentile float64 `json:"-"`
	ScoreRaw   string  `json:"epss"`
	PctileRaw  string  `json:"percentile"`
	Date       string  `json:"date"`
}

type EPSSResponse struct {
	Data []EPSSScore `json:"data"`
}

func (c *EPSSClient) LookupBatch(
	ctx context.Context,
	cveIDs []string,
) (map[string]EPSSScore, error) {
	out := map[string]EPSSScore{}
	for i := 0; i < len(cveIDs); i += epssBatchSize {
		end := i + epssBatchSize
		if end > len(cveIDs) {
			end = len(cveIDs)
		}
		chunk := cveIDs[i:end]
		q := url.Values{"cve": []string{strings.Join(chunk, ",")}}
		var resp EPSSResponse
		if err := c.hx.GetJSON(ctx, pathEPSS, q, &resp); err != nil {
			return nil, fmt.Errorf("epss batch [%d:%d]: %w", i, end, err)
		}
		for _, s := range resp.Data {
			s.Score, _ = strconv.ParseFloat(s.ScoreRaw, 64)
			s.Percentile, _ = strconv.ParseFloat(s.PctileRaw, 64)
			out[s.CveID] = s
		}
	}
	return out, nil
}
