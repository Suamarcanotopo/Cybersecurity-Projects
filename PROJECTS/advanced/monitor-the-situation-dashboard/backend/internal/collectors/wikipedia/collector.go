// ©AngelaMos | 2026
// collector.go

package wikipedia

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name                = "wikipedia"
	defaultWikiInterval = 5 * time.Minute
	idHashBytes         = 16
)

type Fetcher interface {
	Fetch(ctx context.Context) (Response, error)
}

type Repository interface {
	RememberRevID(ctx context.Context, revID int64) error
	LastRevID(ctx context.Context) (int64, bool, error)
	Insert(ctx context.Context, e Entry) error
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
		cfg.Interval = defaultWikiInterval
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
	resp, err := c.cfg.Fetcher.Fetch(ctx)
	if err != nil {
		c.logger.Warn("wikipedia fetch", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}

	last, found, err := c.cfg.Repo.LastRevID(ctx)
	if err != nil {
		c.logger.Warn("wikipedia revid lookup", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}
	if found && last == resp.RevID {
		c.cfg.State.RecordSuccess(ctx, Name, 0)
		return
	}

	entries := ParseEntries(resp.HTML)
	now := time.Now().UTC()
	emitted := int64(0)
	for _, e := range entries {
		id := entryID(e)
		body, _ := json.Marshal(map[string]any{
			"text": e.Text,
			"slug": e.ArticleSlug,
		})
		entry := Entry{
			ID:         id,
			Headline:   e.Text,
			OccurredAt: now,
			Payload:    body,
		}
		if err := c.cfg.Repo.Insert(ctx, entry); err != nil {
			c.logger.Warn("wikipedia insert", "id", id, "err", err)
			continue
		}
		c.cfg.Emitter.Emit(events.Event{
			Topic:     events.TopicWikipediaITN,
			Timestamp: now,
			Source:    Name,
			Payload:   json.RawMessage(body),
		})
		emitted++
	}

	if err := c.cfg.Repo.RememberRevID(ctx, resp.RevID); err != nil {
		c.logger.Warn("wikipedia remember revid", "err", err)
	}
	c.cfg.State.RecordSuccess(ctx, Name, emitted)
}

func entryID(e ITNEntry) string {
	h := sha256.Sum256([]byte(e.Text + "|" + e.ArticleSlug))
	return hex.EncodeToString(h[:idHashBytes])
}
