// ©AngelaMos | 2026
// collector.go

package gdelt

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name                 = "gdelt"
	defaultGDELTInterval = 15 * time.Minute
	defaultBaselineCap   = 96
	zScoreSpikeThreshold = 3.0
	idHashBytes          = 16
)

type Fetcher interface {
	FetchTheme(ctx context.Context, theme string) ([]ThemeBucket, error)
}

type Repository interface {
	Insert(ctx context.Context, row SpikeRow) (inserted bool, err error)
}

type Emitter interface {
	Emit(ev events.Event)
}

type StateRecorder interface {
	RecordSuccess(ctx context.Context, name string, eventCount int64)
	RecordError(ctx context.Context, name, errMsg string)
}

type CollectorConfig struct {
	Interval    time.Duration
	Themes      []string
	BaselineCap int
	Fetcher     Fetcher
	Repo        Repository
	Emitter     Emitter
	State       StateRecorder
	Logger      *slog.Logger
}

type Collector struct {
	cfg       CollectorConfig
	logger    *slog.Logger
	baselines map[string]*ThemeState
}

func NewCollector(cfg CollectorConfig) *Collector {
	if cfg.Interval <= 0 {
		cfg.Interval = defaultGDELTInterval
	}
	if cfg.BaselineCap <= 0 {
		cfg.BaselineCap = defaultBaselineCap
	}
	if len(cfg.Themes) == 0 {
		cfg.Themes = DefaultThemes
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	c := &Collector{
		cfg:       cfg,
		logger:    cfg.Logger,
		baselines: make(map[string]*ThemeState, len(cfg.Themes)),
	}
	for _, t := range cfg.Themes {
		c.baselines[t] = NewThemeState(cfg.BaselineCap)
	}
	return c
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
	hadError := false
	emitted := int64(0)

	for _, theme := range c.cfg.Themes {
		buckets, err := c.cfg.Fetcher.FetchTheme(ctx, theme)
		if err != nil {
			c.logger.Warn("gdelt fetch", "theme", theme, "err", err)
			c.cfg.State.RecordError(ctx, Name, err.Error())
			hadError = true
			continue
		}
		baseline := c.baselines[theme]
		for _, b := range buckets {
			z := baseline.ZScore(b.Count)
			baseline.Push(Bucket{Score: b.Time.UnixMilli(), Count: b.Count})

			if z <= zScoreSpikeThreshold {
				continue
			}
			id := spikeID(theme, b.Time)

			payload, perr := json.Marshal(map[string]any{
				"theme":  theme,
				"time":   b.Time,
				"count":  b.Count,
				"zscore": z,
			})
			if perr != nil {
				c.logger.Warn(
					"gdelt marshal payload",
					"theme",
					theme,
					"err",
					perr,
				)
				continue
			}
			row := SpikeRow{
				ID:         id,
				Theme:      theme,
				OccurredAt: b.Time,
				Headline: fmt.Sprintf(
					"Theme spike: %s (z=%.2f, count=%d)",
					theme,
					z,
					b.Count,
				),
				Payload: payload,
			}
			inserted, ierr := c.cfg.Repo.Insert(ctx, row)
			if ierr != nil {
				c.logger.Warn("gdelt insert", "id", id, "err", ierr)
				continue
			}
			if !inserted {
				continue
			}
			c.cfg.Emitter.Emit(events.Event{
				Topic:     events.TopicGDELTSpike,
				Timestamp: b.Time,
				Source:    Name,
				Payload:   json.RawMessage(payload),
			})
			emitted++
		}
	}

	if !hadError {
		c.cfg.State.RecordSuccess(ctx, Name, emitted)
	}
}

func spikeID(theme string, t time.Time) string {
	h := sha256.Sum256([]byte(theme + "|" + t.UTC().Format(time.RFC3339)))
	return hex.EncodeToString(h[:idHashBytes])
}
