// ©AngelaMos | 2026
// client.go

package kev

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

const (
	defaultKEVURL        = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
	defaultKEVRate       = time.Second
	defaultKEVBudget     = 5
	defaultKEVBreakerWin = 60 * time.Second
)

type ClientConfig struct {
	URL string
}

type Client struct {
	hx *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.URL == "" {
		cfg.URL = defaultKEVURL
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "kev",
			BaseURL:                  cfg.URL,
			Rate:                     rate.Every(defaultKEVRate),
			Burst:                    1,
			ConsecutiveFailureBudget: defaultKEVBudget,
			BreakerTimeout:           defaultKEVBreakerWin,
		}),
	}
}

type Catalog struct {
	Title           string          `json:"title"`
	CatalogVersion  string          `json:"catalogVersion"`
	DateReleased    string          `json:"dateReleased"`
	Count           int             `json:"count"`
	Vulnerabilities []Vulnerability `json:"vulnerabilities"`
}

type Vulnerability struct {
	CveID                      string `json:"cveID"`
	VendorProject              string `json:"vendorProject"`
	Product                    string `json:"product"`
	VulnerabilityName          string `json:"vulnerabilityName"`
	DateAdded                  string `json:"dateAdded"`
	DueDate                    string `json:"dueDate"`
	KnownRansomwareCampaignUse string `json:"knownRansomwareCampaignUse"`
	ShortDescription           string `json:"shortDescription"`
	RequiredAction             string `json:"requiredAction"`
}

func (c *Client) FetchCatalog(ctx context.Context) (Catalog, error) {
	resp, err := c.hx.Get(ctx, "", nil)
	if err != nil {
		return Catalog{}, fmt.Errorf("fetch kev catalog: %w", err)
	}
	defer resp.Body.Close()

	var cat Catalog
	if err := json.NewDecoder(resp.Body).Decode(&cat); err != nil {
		return Catalog{}, fmt.Errorf("decode kev: %w", err)
	}
	return cat, nil
}
