// ©AngelaMos | 2026
// client.go

package swpc

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
	defaultSWPCBaseURL = "https://services.swpc.noaa.gov"
	pathPlasma         = "/products/solar-wind/plasma-5-minute.json"
	pathMag            = "/products/solar-wind/mag-5-minute.json"
	pathKp             = "/products/noaa-planetary-k-index.json"
	pathXray           = "/json/goes/primary/xrays-1-day.json"
	pathAlerts         = "/products/alerts.json"
	defaultSWPCRate    = 200 * time.Millisecond
	defaultSWPCBurst   = 5
	defaultSWPCBudget  = 5
	defaultSWPCBreaker = 60 * time.Second
)

type ClientConfig struct {
	BaseURL string
}

type Client struct {
	hx *httpx.Client
}

func NewClient(cfg ClientConfig) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultSWPCBaseURL
	}
	return &Client{
		hx: httpx.New(httpx.Config{
			Name:                     "swpc",
			BaseURL:                  cfg.BaseURL,
			Rate:                     rate.Every(defaultSWPCRate),
			Burst:                    defaultSWPCBurst,
			ConsecutiveFailureBudget: defaultSWPCBudget,
			BreakerTimeout:           defaultSWPCBreaker,
		}),
	}
}

type PlasmaTick struct {
	TimeTag     time.Time
	Density     string
	Speed       string
	Temperature string
}

type MagTick struct {
	TimeTag time.Time
	BxGSM   string
	ByGSM   string
	BzGSM   string
	LonGSM  string
	LatGSM  string
	Bt      string
}

type KpTick struct {
	TimeTag      time.Time
	Kp           float64
	ARunning     int
	StationCount int
}

type XrayTick struct {
	TimeTag      time.Time
	Satellite    int
	Flux         float64
	ObservedFlux float64
	Energy       string
}

type AlertItem struct {
	ProductID     string
	IssueDatetime time.Time
	Message       string
}

func (c *Client) FetchPlasma(ctx context.Context) ([]PlasmaTick, error) {
	rows, err := c.fetchRowArray(ctx, pathPlasma)
	if err != nil {
		return nil, err
	}
	out := make([]PlasmaTick, 0, len(rows))
	for _, r := range rows {
		ts, _ := ParseTime(r["time_tag"])
		out = append(out, PlasmaTick{
			TimeTag:     ts,
			Density:     r["density"],
			Speed:       r["speed"],
			Temperature: r["temperature"],
		})
	}
	return out, nil
}

func (c *Client) FetchMag(ctx context.Context) ([]MagTick, error) {
	rows, err := c.fetchRowArray(ctx, pathMag)
	if err != nil {
		return nil, err
	}
	out := make([]MagTick, 0, len(rows))
	for _, r := range rows {
		ts, _ := ParseTime(r["time_tag"])
		out = append(out, MagTick{
			TimeTag: ts,
			BxGSM:   r["bx_gsm"],
			ByGSM:   r["by_gsm"],
			BzGSM:   r["bz_gsm"],
			LonGSM:  r["lon_gsm"],
			LatGSM:  r["lat_gsm"],
			Bt:      r["bt"],
		})
	}
	return out, nil
}

type rawKp struct {
	TimeTag      string  `json:"time_tag"`
	Kp           float64 `json:"Kp"`
	ARunning     int     `json:"a_running"`
	StationCount int     `json:"station_count"`
}

func (c *Client) FetchKp(ctx context.Context) ([]KpTick, error) {
	var rows []rawKp
	if err := c.hx.GetJSON(ctx, pathKp, nil, &rows); err != nil {
		return nil, fmt.Errorf("fetch kp: %w", err)
	}
	out := make([]KpTick, 0, len(rows))
	for _, r := range rows {
		ts, _ := ParseTime(r.TimeTag)
		out = append(out, KpTick{
			TimeTag:      ts,
			Kp:           r.Kp,
			ARunning:     r.ARunning,
			StationCount: r.StationCount,
		})
	}
	return out, nil
}

type rawXray struct {
	TimeTag      string  `json:"time_tag"`
	Satellite    int     `json:"satellite"`
	Flux         float64 `json:"flux"`
	ObservedFlux float64 `json:"observed_flux"`
	Energy       string  `json:"energy"`
}

func (c *Client) FetchXray(ctx context.Context) ([]XrayTick, error) {
	var rows []rawXray
	if err := c.hx.GetJSON(ctx, pathXray, nil, &rows); err != nil {
		return nil, fmt.Errorf("fetch xray: %w", err)
	}
	out := make([]XrayTick, 0, len(rows))
	for _, r := range rows {
		ts, _ := ParseTime(r.TimeTag)
		out = append(out, XrayTick{
			TimeTag:      ts,
			Satellite:    r.Satellite,
			Flux:         r.Flux,
			ObservedFlux: r.ObservedFlux,
			Energy:       r.Energy,
		})
	}
	return out, nil
}

type rawAlert struct {
	ProductID     string `json:"product_id"`
	IssueDatetime string `json:"issue_datetime"`
	Message       string `json:"message"`
}

func (c *Client) FetchAlerts(ctx context.Context) ([]AlertItem, error) {
	var rows []rawAlert
	if err := c.hx.GetJSON(ctx, pathAlerts, nil, &rows); err != nil {
		return nil, fmt.Errorf("fetch alerts: %w", err)
	}
	out := make([]AlertItem, 0, len(rows))
	for _, r := range rows {
		ts, _ := ParseTime(r.IssueDatetime)
		out = append(out, AlertItem{
			ProductID:     r.ProductID,
			IssueDatetime: ts,
			Message:       r.Message,
		})
	}
	return out, nil
}

func (c *Client) fetchRowArray(
	ctx context.Context,
	path string,
) ([]map[string]string, error) {
	var raw [][]any
	if err := c.hx.GetJSON(ctx, path, nil, &raw); err != nil {
		return nil, fmt.Errorf("fetch row-array %s: %w", path, err)
	}
	if len(raw) < 2 {
		return nil, nil
	}
	headers := make([]string, 0, len(raw[0]))
	for _, h := range raw[0] {
		if s, ok := h.(string); ok {
			headers = append(headers, s)
		}
	}
	out := make([]map[string]string, 0, len(raw)-1)
	for _, row := range raw[1:] {
		m := make(map[string]string, len(headers))
		for i, v := range row {
			if i >= len(headers) {
				break
			}
			m[headers[i]] = anyToString(v)
		}
		out = append(out, m)
	}
	return out, nil
}

func anyToString(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case json.Number:
		return x.String()
	case bool:
		return strconv.FormatBool(x)
	default:
		return ""
	}
}

var swpcTimeFormats = []string{
	time.RFC3339Nano,
	"2006-01-02T15:04:05Z",
	"2006-01-02T15:04:05",
	"2006-01-02 15:04:05.000",
	"2006-01-02 15:04:05",
}

func ParseTime(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, fmt.Errorf("empty swpc time")
	}
	for _, f := range swpcTimeFormats {
		if t, err := time.Parse(f, s); err == nil {
			return t.UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("unrecognized swpc time: %q", s)
}
