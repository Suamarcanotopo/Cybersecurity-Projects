// ©AngelaMos | 2026
// collector.go

package dshield

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name            = "dshield"
	defaultInterval = time.Hour
)

type Fetcher interface {
	FetchAll(ctx context.Context) ([]SnapshotPayload, error)
}

type DShieldEnrichment struct {
	Country        string
	Classification string
	Actor          string
}

type Enricher interface {
	Lookup(ctx context.Context, ip string) (DShieldEnrichment, error)
}

type Persister interface {
	PutSnapshot(
		ctx context.Context,
		ts time.Time,
		kind string,
		payload json.RawMessage,
	) error
}

type Emitter interface {
	Emit(ev events.Event)
}

type StateRecorder interface {
	RecordSuccess(ctx context.Context, name string, eventCount int64)
	RecordError(ctx context.Context, name, errMsg string)
}

type CollectorConfig struct {
	Interval  time.Duration
	Fetcher   Fetcher
	Persister Persister
	Emitter   Emitter
	State     StateRecorder
	Enricher  Enricher
	Logger    *slog.Logger
}

type Collector struct {
	cfg    CollectorConfig
	logger *slog.Logger
}

func NewCollector(cfg CollectorConfig) *Collector {
	if cfg.Interval <= 0 {
		cfg.Interval = defaultInterval
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
	snaps, err := c.cfg.Fetcher.FetchAll(ctx)
	if err != nil {
		c.logger.Warn("dshield fetch failed", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}

	now := time.Now().UTC()
	tsRaw, err := json.Marshal(now.Format(time.RFC3339Nano))
	if err != nil {
		c.logger.Error("dshield marshal ts", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}

	merged := map[string]json.RawMessage{"ts": tsRaw}
	for _, s := range snaps {
		payload := s.Payload
		if s.Kind == KindTopIPs {
			payload = c.enrichSources(ctx, payload)
		}
		if perr := c.cfg.Persister.PutSnapshot(
			ctx,
			now,
			s.Kind,
			payload,
		); perr != nil {
			c.logger.Warn("dshield persist failed", "kind", s.Kind, "err", perr)
		}
		merged[s.Kind] = payload
	}

	body, err := json.Marshal(merged)
	if err != nil {
		c.logger.Error("dshield marshal merged", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}

	c.cfg.Emitter.Emit(events.Event{
		Topic:     events.TopicScanFirehose,
		Timestamp: now,
		Source:    Name,
		Payload:   json.RawMessage(body),
	})
	c.cfg.State.RecordSuccess(ctx, Name, 1)
}

func (c *Collector) enrichSources(
	ctx context.Context,
	raw json.RawMessage,
) json.RawMessage {
	if c.cfg.Enricher == nil {
		return raw
	}
	var srcs []RawSource
	if err := json.Unmarshal(raw, &srcs); err != nil {
		return raw
	}
	enriched := make([]EnrichedSource, 0, len(srcs))
	for _, s := range srcs {
		e := EnrichedSource{
			Rank:    s.Rank,
			Source:  s.Source,
			Reports: s.Reports,
			Targets: s.Targets,
		}
		if info, err := c.cfg.Enricher.Lookup(ctx, s.Source); err == nil {
			e.Country = info.Country
			e.Classification = info.Classification
			e.Actor = info.Actor
		}
		enriched = append(enriched, e)
	}
	out, err := json.Marshal(enriched)
	if err != nil {
		return raw
	}
	return out
}
