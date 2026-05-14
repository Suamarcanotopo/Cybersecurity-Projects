// ©AngelaMos | 2026
// collector.go

package kev

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name              = "kev"
	defaultKEVCadence = time.Hour
	dateLayout        = "2006-01-02"
)

type Fetcher interface {
	FetchCatalog(ctx context.Context) (Catalog, error)
}

type Repository interface {
	Insert(ctx context.Context, row Row) error
	KnownIDs(ctx context.Context, ids []string) (map[string]bool, error)
}

type Emitter interface {
	Emit(ev events.Event)
}

type StateRecorder interface {
	RecordSuccess(ctx context.Context, name string, eventCount int64)
	RecordError(ctx context.Context, name, errMsg string)
}

type CollectorConfig struct {
	Interval time.Duration
	Fetcher  Fetcher
	Repo     Repository
	Emitter  Emitter
	State    StateRecorder
	Logger   *slog.Logger
}

type Collector struct {
	cfg    CollectorConfig
	logger *slog.Logger
}

func NewCollector(cfg CollectorConfig) *Collector {
	if cfg.Interval <= 0 {
		cfg.Interval = defaultKEVCadence
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
	cat, err := c.cfg.Fetcher.FetchCatalog(ctx)
	if err != nil {
		c.logger.Warn("kev fetch", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}

	ids := make([]string, 0, len(cat.Vulnerabilities))
	for _, v := range cat.Vulnerabilities {
		ids = append(ids, v.CveID)
	}

	known, err := c.cfg.Repo.KnownIDs(ctx, ids)
	if err != nil {
		c.logger.Warn("kev known ids", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}

	now := time.Now().UTC()
	emitted := int64(0)
	for _, v := range cat.Vulnerabilities {
		if known[v.CveID] {
			continue
		}

		dateAdded, _ := time.Parse(dateLayout, v.DateAdded)
		var dueDate *time.Time
		if t, perr := time.Parse(dateLayout, v.DueDate); perr == nil {
			dueDate = &t
		}

		raw, _ := json.Marshal(v)
		row := Row{
			CveID:             v.CveID,
			Vendor:            v.VendorProject,
			Product:           v.Product,
			VulnerabilityName: v.VulnerabilityName,
			DateAdded:         dateAdded,
			DueDate:           dueDate,
			RansomwareUse:     v.KnownRansomwareCampaignUse,
			Payload:           raw,
		}

		if ierr := c.cfg.Repo.Insert(ctx, row); ierr != nil {
			c.logger.Warn("kev insert", "id", v.CveID, "err", ierr)
			continue
		}

		c.cfg.Emitter.Emit(events.Event{
			Topic:     events.TopicKEVAdded,
			Timestamp: now,
			Source:    Name,
			Payload:   json.RawMessage(raw),
		})
		emitted++
	}
	c.cfg.State.RecordSuccess(ctx, Name, emitted)
}
