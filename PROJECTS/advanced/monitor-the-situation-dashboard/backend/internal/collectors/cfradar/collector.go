// ©AngelaMos | 2026
// collector.go

package cfradar

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/netip"
	"time"

	"github.com/lib/pq"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name                       = "cfradar"
	defaultCollectorInterval   = 5 * time.Minute
	defaultCollectorConfidence = 7
)

type Fetcher interface {
	FetchOutages(ctx context.Context) (OutageResultBody, error)
	FetchHijacks(ctx context.Context, minConfidence int) (HijackBody, error)
}

type Repository interface {
	UpsertOutage(ctx context.Context, o OutageRow) error
	UpsertHijack(ctx context.Context, h HijackRow) error
	KnownOutageIDs(ctx context.Context, ids []string) (map[string]bool, error)
	KnownHijackIDs(ctx context.Context, ids []int64) (map[int64]bool, error)
}

type Emitter interface {
	Emit(ev events.Event)
}

type StateRecorder interface {
	RecordSuccess(ctx context.Context, name string, eventCount int64)
	RecordError(ctx context.Context, name, errMsg string)
}

type Enricher interface {
	Lookup(ctx context.Context, ip string) (Enrichment, error)
}

type Enrichment struct {
	Country         string `json:"country,omitempty"`
	AbuseConfidence int    `json:"abuse_confidence,omitempty"`
	ISP             string `json:"isp,omitempty"`
	CheckedIP       string `json:"checked_ip,omitempty"`
}

type EnrichedHijack struct {
	HijackEvent
	Enrichment *Enrichment `json:"enrichment,omitempty"`
}

type CollectorConfig struct {
	Interval      time.Duration
	MinConfidence int
	Fetcher       Fetcher
	Repo          Repository
	Emitter       Emitter
	State         StateRecorder
	Enricher      Enricher
	Logger        *slog.Logger
}

type Collector struct {
	cfg    CollectorConfig
	logger *slog.Logger
}

func NewCollector(cfg CollectorConfig) *Collector {
	if cfg.Interval <= 0 {
		cfg.Interval = defaultCollectorInterval
	}
	if cfg.MinConfidence <= 0 {
		cfg.MinConfidence = defaultCollectorConfidence
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	return &Collector{cfg: cfg, logger: cfg.Logger}
}

func (c *Collector) Name() string { return Name }

func (c *Collector) Run(ctx context.Context) error {
	ticker := time.NewTicker(c.cfg.Interval)
	defer ticker.Stop()

	c.tick(ctx)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			c.tick(ctx)
		}
	}
}

func (c *Collector) tick(ctx context.Context) {
	emitted := int64(0)
	hadError := false

	if n, err := c.tickOutages(ctx); err != nil {
		c.logger.Warn("cfradar outages tick failed", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		hadError = true
	} else {
		emitted += n
	}

	if n, err := c.tickHijacks(ctx); err != nil {
		c.logger.Warn("cfradar hijacks tick failed", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		hadError = true
	} else {
		emitted += n
	}

	if !hadError {
		c.cfg.State.RecordSuccess(ctx, Name, emitted)
	}
}

func (c *Collector) tickOutages(ctx context.Context) (int64, error) {
	body, err := c.cfg.Fetcher.FetchOutages(ctx)
	if err != nil {
		return 0, err
	}

	ids := make([]string, 0, len(body.Annotations))
	for _, a := range body.Annotations {
		ids = append(ids, a.ID)
	}

	known, err := c.cfg.Repo.KnownOutageIDs(ctx, ids)
	if err != nil {
		return 0, err
	}

	now := time.Now().UTC()
	emitted := int64(0)
	for _, a := range body.Annotations {
		if known[a.ID] {
			continue
		}
		rawBytes, _ := json.Marshal(a)
		raw := json.RawMessage(rawBytes)
		row := OutageRow{
			ID:         a.ID,
			StartedAt:  a.StartDate,
			EndedAt:    a.EndDate,
			Locations:  pq.StringArray(a.Locations),
			ASNs:       pq.Int32Array(a.ASNs),
			Cause:      a.Reason,
			OutageType: a.OutageType,
			Payload:    raw,
		}
		if uerr := c.cfg.Repo.UpsertOutage(ctx, row); uerr != nil {
			c.logger.Warn("upsert outage", "id", a.ID, "err", uerr)
			continue
		}
		c.cfg.Emitter.Emit(events.Event{
			Topic:     events.TopicInternetOutage,
			Timestamp: now,
			Source:    Name,
			Payload:   raw,
		})
		emitted++
	}
	return emitted, nil
}

func (c *Collector) tickHijacks(ctx context.Context) (int64, error) {
	body, err := c.cfg.Fetcher.FetchHijacks(ctx, c.cfg.MinConfidence)
	if err != nil {
		return 0, err
	}

	ids := make([]int64, 0, len(body.Events))
	for _, e := range body.Events {
		ids = append(ids, e.ID)
	}

	known, err := c.cfg.Repo.KnownHijackIDs(ctx, ids)
	if err != nil {
		return 0, err
	}

	now := time.Now().UTC()
	emitted := int64(0)
	for _, e := range body.Events {
		if known[e.ID] {
			continue
		}
		enriched := EnrichedHijack{HijackEvent: e}
		if c.cfg.Enricher != nil && len(e.Prefixes) > 0 {
			if ip, ok := representativeIP(e.Prefixes[0]); ok {
				if v, lerr := c.cfg.Enricher.Lookup(ctx, ip); lerr == nil {
					enriched.Enrichment = &Enrichment{
						Country:         v.Country,
						AbuseConfidence: v.AbuseConfidence,
						ISP:             v.ISP,
						CheckedIP:       ip,
					}
				}
			}
		}
		rawBytes, _ := json.Marshal(enriched)
		raw := json.RawMessage(rawBytes)
		row := HijackRow{
			ID:          e.ID,
			DetectedAt:  e.DetectedAt,
			StartedAt:   e.StartedAt,
			DurationSec: e.DurationSec,
			Confidence:  e.Confidence,
			HijackerASN: e.HijackerASN,
			VictimASNs:  pq.Int32Array(e.VictimASNs),
			Prefixes:    e.Prefixes,
			Payload:     raw,
		}
		if uerr := c.cfg.Repo.UpsertHijack(ctx, row); uerr != nil {
			c.logger.Warn("upsert hijack", "id", e.ID, "err", uerr)
			continue
		}
		c.cfg.Emitter.Emit(events.Event{
			Topic:     events.TopicBGPHijack,
			Timestamp: now,
			Source:    Name,
			Payload:   raw,
		})
		emitted++
	}
	return emitted, nil
}

func representativeIP(cidr string) (string, bool) {
	p, err := netip.ParsePrefix(cidr)
	if err != nil {
		return "", false
	}
	return p.Addr().String(), true
}
