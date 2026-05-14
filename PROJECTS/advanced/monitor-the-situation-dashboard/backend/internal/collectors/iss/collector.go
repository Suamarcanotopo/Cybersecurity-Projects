// ©AngelaMos | 2026
// collector.go

package iss

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name                    = "iss"
	defaultPositionInterval = 10 * time.Second
	defaultTLEInterval      = 24 * time.Hour
)

type Fetcher interface {
	FetchPosition(ctx context.Context) (Position, error)
	FetchTLE(ctx context.Context) (TLE, error)
}

type TLEStorer interface {
	Save(ctx context.Context, tle TLE) error
	Load(ctx context.Context) (TLE, bool, error)
}

type Emitter interface {
	Emit(ev events.Event)
}

type StateRecorder interface {
	RecordSuccess(ctx context.Context, name string, eventCount int64)
	RecordError(ctx context.Context, name, errMsg string)
}

type CollectorConfig struct {
	PositionInterval time.Duration
	TLEInterval      time.Duration
	Fetcher          Fetcher
	TLEStore         TLEStorer
	Emitter          Emitter
	State            StateRecorder
	Logger           *slog.Logger
}

type Collector struct {
	cfg    CollectorConfig
	logger *slog.Logger
}

func NewCollector(cfg CollectorConfig) *Collector {
	if cfg.PositionInterval <= 0 {
		cfg.PositionInterval = defaultPositionInterval
	}
	if cfg.TLEInterval <= 0 {
		cfg.TLEInterval = defaultTLEInterval
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	return &Collector{cfg: cfg, logger: cfg.Logger}
}

func (c *Collector) Name() string { return Name }

func (c *Collector) Run(ctx context.Context) error {
	pos := time.NewTicker(c.cfg.PositionInterval)
	defer pos.Stop()
	tle := time.NewTicker(c.cfg.TLEInterval)
	defer tle.Stop()

	c.tickPosition(ctx)
	c.tickTLE(ctx)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-pos.C:
			c.tickPosition(ctx)
		case <-tle.C:
			c.tickTLE(ctx)
		}
	}
}

func (c *Collector) tickPosition(ctx context.Context) {
	p, err := c.cfg.Fetcher.FetchPosition(ctx)
	if err != nil {
		c.logger.Warn("iss position fetch", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}
	body, _ := json.Marshal(p)
	c.cfg.Emitter.Emit(events.Event{
		Topic:     events.TopicISSPosition,
		Timestamp: p.FetchedAt,
		Source:    Name,
		Payload:   json.RawMessage(body),
	})
	c.cfg.State.RecordSuccess(ctx, Name, 1)
}

func (c *Collector) tickTLE(ctx context.Context) {
	tle, err := c.cfg.Fetcher.FetchTLE(ctx)
	if err != nil {
		c.logger.Warn("iss tle fetch", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}
	if err := c.cfg.TLEStore.Save(ctx, tle); err != nil {
		c.logger.Warn("iss tle save", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
	}
}
