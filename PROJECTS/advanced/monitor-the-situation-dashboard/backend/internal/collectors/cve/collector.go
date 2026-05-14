// ©AngelaMos | 2026
// collector.go

package cve

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name               = "cve"
	defaultCVEInterval = 2 * time.Hour
	defaultCVEWindow   = 2 * time.Hour
)

type NVDFetcher interface {
	Fetch(ctx context.Context, start, end time.Time) (NVDResponse, error)
}

type EPSSFetcher interface {
	LookupBatch(
		ctx context.Context,
		cveIDs []string,
	) (map[string]EPSSScore, error)
}

type Repository interface {
	Upsert(ctx context.Context, row Row) error
	UpdateEPSS(
		ctx context.Context,
		cveID string,
		score, percentile float64,
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
	Interval time.Duration
	Window   time.Duration
	NVD      NVDFetcher
	EPSS     EPSSFetcher
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
		cfg.Interval = defaultCVEInterval
	}
	if cfg.Window <= 0 {
		cfg.Window = defaultCVEWindow
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
	end := time.Now().UTC()
	start := end.Add(-c.cfg.Window)

	resp, err := c.cfg.NVD.Fetch(ctx, start, end)
	if err != nil {
		c.logger.Warn("nvd fetch", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}

	ids := make([]string, 0, len(resp.Vulnerabilities))
	rows := make([]Row, 0, len(resp.Vulnerabilities))
	for _, v := range resp.Vulnerabilities {
		score, severity := v.PrimarySeverity()
		raw, _ := json.Marshal(v)
		row := Row{
			CveID:        v.CVE.ID,
			Published:    v.CVE.Published.Time,
			LastModified: v.CVE.LastModified.Time,
			Severity:     severity,
			CVSS:         score,
			Payload:      raw,
		}
		rows = append(rows, row)
		ids = append(ids, v.CVE.ID)
	}

	scores, err := c.cfg.EPSS.LookupBatch(ctx, ids)
	if err != nil {
		c.logger.Warn("epss lookup", "err", err)
	}

	emitted := int64(0)
	for _, row := range rows {
		if err := c.cfg.Repo.Upsert(ctx, row); err != nil {
			c.logger.Warn("upsert cve", "id", row.CveID, "err", err)
			continue
		}
		if s, ok := scores[row.CveID]; ok {
			if err := c.cfg.Repo.UpdateEPSS(
				ctx,
				row.CveID,
				s.Score,
				s.Percentile,
			); err != nil {
				c.logger.Warn("update epss", "id", row.CveID, "err", err)
			}
			row.EPSSScore = &s.Score
			row.EPSSPercentile = &s.Percentile
		}
		body, _ := json.Marshal(row)
		c.cfg.Emitter.Emit(events.Event{
			Topic:     events.TopicCVENew,
			Timestamp: end,
			Source:    Name,
			Payload:   json.RawMessage(body),
		})
		emitted++
	}
	c.cfg.State.RecordSuccess(ctx, Name, emitted)
}
