// ©AngelaMos | 2026
// collector.go

package usgs

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name                 = "usgs"
	defaultUSGSInterval  = time.Minute
	defaultLogPlaceLimit = 64
)

type Fetcher interface {
	Fetch(ctx context.Context) (Feed, error)
}

type Repository interface {
	Upsert(ctx context.Context, row Row) error
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
		cfg.Interval = defaultUSGSInterval
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
	feed, err := c.cfg.Fetcher.Fetch(ctx)
	if err != nil {
		c.logger.Warn("usgs fetch", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}

	ids := make([]string, 0, len(feed.Features))
	for _, f := range feed.Features {
		ids = append(ids, f.ID)
	}
	known, err := c.cfg.Repo.KnownIDs(ctx, ids)
	if err != nil {
		c.logger.Warn("usgs known ids", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}

	emitted := int64(0)
	now := time.Now().UTC()
	for _, f := range feed.Features {
		raw, _ := json.Marshal(f)
		row := Row{
			ID:         f.ID,
			OccurredAt: f.Properties.OccurredAt(),
			Mag:        f.Properties.Mag,
			Place:      f.Properties.Place,
			GeomLat:    coord(f.Geometry.Coordinates, 1),
			GeomLon:    coord(f.Geometry.Coordinates, 0),
			DepthKm:    coord(f.Geometry.Coordinates, 2),
			Payload:    raw,
		}
		if err := c.cfg.Repo.Upsert(ctx, row); err != nil {
			c.logger.Warn("usgs upsert", "id", row.ID, "err", err)
			continue
		}
		if known[f.ID] {
			continue
		}
		c.cfg.Emitter.Emit(events.Event{
			Topic:     events.TopicEarthquake,
			Timestamp: now,
			Source:    Name,
			Payload:   json.RawMessage(raw),
		})
		emitted++
	}
	c.cfg.State.RecordSuccess(ctx, Name, emitted)
}

func coord(c []float64, i int) float64 {
	if i < len(c) {
		return c[i]
	}
	return 0
}
