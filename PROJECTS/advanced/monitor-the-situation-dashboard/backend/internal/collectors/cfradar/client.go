// ©AngelaMos | 2026
// client.go

package cfradar

import (
	"context"
	"fmt"
	"net/url"
	"strconv"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	defaultCFBaseURL = "https://api.cloudflare.com"
	defaultCFRate    = 250 * time.Millisecond
	defaultCFBurst   = 5
	defaultCFBudget  = 5
	defaultCFBreaker = 60 * time.Second
	pathRadarOutages = "/client/v4/radar/annotations/outages"
	pathRadarHijacks = "/client/v4/radar/bgp/hijacks/events"
	defaultDateRange = "1d"
)

type ClientConfig struct {
	BaseURL     string
	BearerToken string
}

type Client struct {
	hx *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultCFBaseURL
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "cfradar",
			BaseURL:                  cfg.BaseURL,
			BearerToken:              cfg.BearerToken,
			Rate:                     rate.Every(defaultCFRate),
			Burst:                    defaultCFBurst,
			ConsecutiveFailureBudget: defaultCFBudget,
			BreakerTimeout:           defaultCFBreaker,
		}),
	}
}

type OutageEnvelope struct {
	Success bool             `json:"success"`
	Result  OutageResultBody `json:"result"`
	Errors  []ErrorEntry     `json:"errors"`
}

type OutageResultBody struct {
	Annotations []OutageAnnotation `json:"annotations"`
}

type OutageAnnotation struct {
	ID         string     `json:"id"`
	StartDate  time.Time  `json:"startDate"`
	EndDate    *time.Time `json:"endDate"`
	Locations  []string   `json:"locations"`
	ASNs       []int32    `json:"asns"`
	Reason     string     `json:"reason"`
	OutageType string     `json:"outageType"`
}

type HijackEnvelope struct {
	Success bool         `json:"success"`
	Result  HijackBody   `json:"result"`
	Errors  []ErrorEntry `json:"errors"`
}

type HijackBody struct {
	Events []HijackEvent `json:"events"`
}

type HijackEvent struct {
	ID          int64     `json:"id"`
	DetectedAt  time.Time `json:"detectedAt"`
	StartedAt   time.Time `json:"startedAt"`
	DurationSec int32     `json:"duration"`
	Confidence  int16     `json:"confidenceScore"`
	HijackerASN int32     `json:"hijackerAsn"`
	VictimASNs  []int32   `json:"victimAsns"`
	Prefixes    []string  `json:"prefixes"`
}

type ErrorEntry struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (c *Client) FetchOutages(ctx context.Context) (OutageResultBody, error) {
	q := url.Values{"dateRange": []string{defaultDateRange}}
	var env OutageEnvelope
	if err := c.hx.GetJSON(ctx, pathRadarOutages, q, &env); err != nil {
		return OutageResultBody{}, fmt.Errorf("fetch outages: %w", err)
	}
	if !env.Success {
		return OutageResultBody{}, fmt.Errorf(
			"radar outages: success=false errors=%v",
			env.Errors,
		)
	}
	return env.Result, nil
}

func (c *Client) FetchHijacks(
	ctx context.Context,
	minConfidence int,
) (HijackBody, error) {
	q := url.Values{
		"dateRange":     []string{defaultDateRange},
		"minConfidence": []string{strconv.Itoa(minConfidence)},
	}
	var env HijackEnvelope
	if err := c.hx.GetJSON(ctx, pathRadarHijacks, q, &env); err != nil {
		return HijackBody{}, fmt.Errorf("fetch hijacks: %w", err)
	}
	if !env.Success {
		return HijackBody{}, fmt.Errorf(
			"radar hijacks: success=false errors=%v",
			env.Errors,
		)
	}
	return env.Result, nil
}
