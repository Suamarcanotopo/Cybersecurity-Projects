// ©AngelaMos | 2026
// collector.go

package swpc

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"strconv"
	"time"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name                = "swpc"
	defaultFastInterval = time.Minute
	defaultSlowInterval = 3 * time.Hour

	keyPlasma = "swpc:plasma"
	keyMag    = "swpc:mag"
	keyKp     = "swpc:kp"
	keyXray   = "swpc:xray"
	keyAlerts = "swpc:alerts"

	xrayBaseB = 1e-7
	xrayBaseC = 1e-6
	xrayBaseM = 1e-5
	xrayBaseX = 1e-4
)

type Fetcher interface {
	FetchPlasma(ctx context.Context) ([]PlasmaTick, error)
	FetchMag(ctx context.Context) ([]MagTick, error)
	FetchKp(ctx context.Context) ([]KpTick, error)
	FetchXray(ctx context.Context) ([]XrayTick, error)
	FetchAlerts(ctx context.Context) ([]AlertItem, error)
}

type Ring interface {
	Push(ctx context.Context, key string, score int64, payload []byte) error
}

type Emitter interface {
	Emit(ev events.Event)
}

type StateRecorder interface {
	RecordSuccess(ctx context.Context, name string, eventCount int64)
	RecordError(ctx context.Context, name, errMsg string)
}

type CollectorConfig struct {
	FastInterval time.Duration
	SlowInterval time.Duration
	Fetcher      Fetcher
	Ring         Ring
	Emitter      Emitter
	State        StateRecorder
	Logger       *slog.Logger
}

type Collector struct {
	cfg    CollectorConfig
	logger *slog.Logger

	latestKp     *KpTick
	latestPlasma *PlasmaTick
	latestMag    *MagTick
	latestXray   *XrayTick
}

func NewCollector(cfg CollectorConfig) *Collector {
	if cfg.FastInterval <= 0 {
		cfg.FastInterval = defaultFastInterval
	}
	if cfg.SlowInterval <= 0 {
		cfg.SlowInterval = defaultSlowInterval
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	return &Collector{cfg: cfg, logger: cfg.Logger}
}

func (c *Collector) Name() string { return Name }

func (c *Collector) Run(ctx context.Context) error {
	fast := time.NewTicker(c.cfg.FastInterval)
	defer fast.Stop()
	slow := time.NewTicker(c.cfg.SlowInterval)
	defer slow.Stop()

	c.tickFast(ctx)
	c.tickSlow(ctx)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-fast.C:
			c.tickFast(ctx)
		case <-slow.C:
			c.tickSlow(ctx)
		}
	}
}

func (c *Collector) tickFast(ctx context.Context) {
	pushed := int64(0)
	hadError := false

	if n, err := c.pushPlasma(ctx); err != nil {
		c.logger.Warn("swpc plasma", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		hadError = true
	} else {
		pushed += n
	}
	if n, err := c.pushMag(ctx); err != nil {
		c.logger.Warn("swpc mag", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		hadError = true
	} else {
		pushed += n
	}
	if n, err := c.pushXray(ctx); err != nil {
		c.logger.Warn("swpc xray", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		hadError = true
	} else {
		pushed += n
	}
	if n, err := c.pushAlerts(ctx); err != nil {
		c.logger.Warn("swpc alerts", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		hadError = true
	} else {
		pushed += n
	}

	if pushed > 0 {
		c.emitCombined(pushed)
	}

	if !hadError {
		c.cfg.State.RecordSuccess(ctx, Name, pushed)
	}
}

func (c *Collector) tickSlow(ctx context.Context) {
	n, err := c.pushKp(ctx)
	if err != nil {
		c.logger.Warn("swpc kp", "err", err)
		c.cfg.State.RecordError(ctx, Name, err.Error())
		return
	}
	if n > 0 {
		c.emitCombined(n)
	}
}

func (c *Collector) emitCombined(pushed int64) {
	body, _ := json.Marshal(c.buildPayload(pushed))
	c.cfg.Emitter.Emit(events.Event{
		Topic:     events.TopicSpaceWeather,
		Timestamp: time.Now().UTC(),
		Source:    Name,
		Payload:   json.RawMessage(body),
	})
}

func (c *Collector) buildPayload(pushed int64) map[string]any {
	out := map[string]any{
		"ts":     time.Now().UTC(),
		"pushed": pushed,
	}
	if c.latestKp != nil {
		out["kp"] = c.latestKp.Kp
	}
	if c.latestPlasma != nil {
		if v, ok := parseSWPCFloat(c.latestPlasma.Speed); ok {
			out["speed_kms"] = v
		}
		if v, ok := parseSWPCFloat(c.latestPlasma.Density); ok {
			out["density"] = v
		}
	}
	if c.latestMag != nil {
		if v, ok := parseSWPCFloat(c.latestMag.BzGSM); ok {
			out["bz_gsm"] = v
		}
	}
	if c.latestXray != nil && c.latestXray.Flux > 0 {
		out["xray_flux"] = c.latestXray.Flux
		if cls := classifyXray(c.latestXray.Flux); cls != "" {
			out["xray_class"] = cls
		}
	}
	return out
}

func (c *Collector) pushPlasma(ctx context.Context) (int64, error) {
	rows, err := c.cfg.Fetcher.FetchPlasma(ctx)
	if err != nil {
		return 0, err
	}
	if latest := lastNonZero(
		rows,
		func(r PlasmaTick) bool { return !r.TimeTag.IsZero() },
	); latest != nil {
		c.latestPlasma = latest
	}
	return pushAll(
		ctx,
		c.cfg.Ring,
		keyPlasma,
		rows,
		func(r PlasmaTick) int64 { return r.TimeTag.UnixMilli() },
	)
}

func (c *Collector) pushMag(ctx context.Context) (int64, error) {
	rows, err := c.cfg.Fetcher.FetchMag(ctx)
	if err != nil {
		return 0, err
	}
	if latest := lastNonZero(
		rows,
		func(r MagTick) bool { return !r.TimeTag.IsZero() },
	); latest != nil {
		c.latestMag = latest
	}
	return pushAll(
		ctx,
		c.cfg.Ring,
		keyMag,
		rows,
		func(r MagTick) int64 { return r.TimeTag.UnixMilli() },
	)
}

func (c *Collector) pushKp(ctx context.Context) (int64, error) {
	rows, err := c.cfg.Fetcher.FetchKp(ctx)
	if err != nil {
		return 0, err
	}
	if latest := lastNonZero(
		rows,
		func(r KpTick) bool { return !r.TimeTag.IsZero() },
	); latest != nil {
		c.latestKp = latest
	}
	return pushAll(
		ctx,
		c.cfg.Ring,
		keyKp,
		rows,
		func(r KpTick) int64 { return r.TimeTag.UnixMilli() },
	)
}

func (c *Collector) pushXray(ctx context.Context) (int64, error) {
	rows, err := c.cfg.Fetcher.FetchXray(ctx)
	if err != nil {
		return 0, err
	}
	if latest := lastNonZero(
		rows,
		func(r XrayTick) bool { return !r.TimeTag.IsZero() },
	); latest != nil {
		c.latestXray = latest
	}
	return pushAll(
		ctx,
		c.cfg.Ring,
		keyXray,
		rows,
		func(r XrayTick) int64 { return r.TimeTag.UnixMilli() },
	)
}

func (c *Collector) pushAlerts(ctx context.Context) (int64, error) {
	rows, err := c.cfg.Fetcher.FetchAlerts(ctx)
	if err != nil {
		return 0, err
	}
	return pushAll(
		ctx,
		c.cfg.Ring,
		keyAlerts,
		rows,
		func(r AlertItem) int64 { return r.IssueDatetime.UnixMilli() },
	)
}

func pushAll[T any](
	ctx context.Context,
	ring Ring,
	key string,
	rows []T,
	score func(T) int64,
) (int64, error) {
	pushed := int64(0)
	for _, r := range rows {
		s := score(r)
		if s == 0 {
			continue
		}
		body, _ := json.Marshal(r)
		if err := ring.Push(ctx, key, s, body); err != nil {
			return pushed, err
		}
		pushed++
	}
	return pushed, nil
}

func lastNonZero[T any](rows []T, ok func(T) bool) *T {
	for i := len(rows) - 1; i >= 0; i-- {
		if ok(rows[i]) {
			r := rows[i]
			return &r
		}
	}
	return nil
}

func parseSWPCFloat(s string) (float64, bool) {
	if s == "" {
		return 0, false
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(f) {
		return 0, false
	}
	return f, true
}

func classifyXray(flux float64) string {
	if flux <= 0 {
		return ""
	}
	if flux >= xrayBaseX {
		return fmt.Sprintf("X%.1f", flux/xrayBaseX)
	}
	if flux >= xrayBaseM {
		return fmt.Sprintf("M%.1f", flux/xrayBaseM)
	}
	if flux >= xrayBaseC {
		return fmt.Sprintf("C%.1f", flux/xrayBaseC)
	}
	if flux >= xrayBaseB {
		return fmt.Sprintf("B%.1f", flux/xrayBaseB)
	}
	return ""
}
