// ©AngelaMos | 2026
// client.go

package abuseipdb

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	defaultAIDBBaseURL    = "https://api.abuseipdb.com"
	pathV2Check           = "/api/v2/check"
	abuseipdbAPIHeader    = "Key"
	defaultAIDBRate       = 1 * time.Second
	defaultAIDBBudget     = 3
	defaultAIDBBreakerWin = 5 * time.Minute
	defaultAIDBRequestTO  = 10 * time.Second
	defaultAIDBMaxAgeDays = 90
)

var ErrUnknownIP = errors.New("abuseipdb: unknown ip")

type ClientConfig struct {
	BaseURL string
	APIKey  string
}

type Client struct {
	hx *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultAIDBBaseURL
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "abuseipdb",
			BaseURL:                  cfg.BaseURL,
			APIKey:                   cfg.APIKey,
			APIKeyHeader:             abuseipdbAPIHeader,
			Rate:                     rate.Every(defaultAIDBRate),
			Burst:                    1,
			ConsecutiveFailureBudget: defaultAIDBBudget,
			BreakerTimeout:           defaultAIDBBreakerWin,
			RequestTimeout:           defaultAIDBRequestTO,
		}),
	}
}

type checkEnvelope struct {
	Data Verdict `json:"data"`
}

type Verdict struct {
	IPAddress            string `json:"ipAddress"`
	IsPublic             bool   `json:"isPublic"`
	IPVersion            int    `json:"ipVersion"`
	IsWhitelisted        bool   `json:"isWhitelisted"`
	AbuseConfidenceScore int    `json:"abuseConfidenceScore"`
	CountryCode          string `json:"countryCode"`
	CountryName          string `json:"countryName"`
	UsageType            string `json:"usageType"`
	ISP                  string `json:"isp"`
	Domain               string `json:"domain"`
	IsTor                bool   `json:"isTor"`
	TotalReports         int    `json:"totalReports"`
	NumDistinctUsers     int    `json:"numDistinctUsers"`
	LastReportedAt       string `json:"lastReportedAt"`
}

func (c *Client) Lookup(ctx context.Context, ip string) (Verdict, error) {
	q := url.Values{
		"ipAddress":    []string{ip},
		"maxAgeInDays": []string{strconv.Itoa(defaultAIDBMaxAgeDays)},
	}
	resp, err := c.hx.Get(ctx, pathV2Check, q)
	if err != nil {
		var se *httpx.StatusError
		if errors.As(err, &se) && se.Code == http.StatusNotFound {
			return Verdict{}, ErrUnknownIP
		}
		return Verdict{}, fmt.Errorf("abuseipdb lookup %s: %w", ip, err)
	}
	defer resp.Body.Close()

	var env checkEnvelope
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		return Verdict{}, fmt.Errorf("abuseipdb decode: %w", err)
	}
	if env.Data.IPAddress == "" {
		return Verdict{}, ErrUnknownIP
	}
	return env.Data, nil
}
