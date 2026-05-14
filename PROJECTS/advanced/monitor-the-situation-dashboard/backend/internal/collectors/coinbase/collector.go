// ©AngelaMos | 2026
// collector.go

package coinbase

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/shopspring/decimal"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	Name            = "coinbase"
	defaultURL      = "wss://advanced-trade-ws.coinbase.com"
	defaultThrottle = 250 * time.Millisecond
)

type Repository interface {
	InsertTick(ctx context.Context, t Tick) error
	UpsertMinute(ctx context.Context, b MinuteBar) error
	LatestTick(ctx context.Context, symbol string) (Tick, error)
	History1h(ctx context.Context, symbol string) ([]MinuteBar, error)
}

type Emitter interface {
	Emit(ev events.Event)
}

type StateRecorder interface {
	RecordSuccess(ctx context.Context, name string, eventCount int64)
	RecordError(ctx context.Context, name, errMsg string)
}

type CollectorConfig struct {
	URL        string
	ProductIDs []string
	Repo       Repository
	Emitter    Emitter
	State      StateRecorder
	Dialer     Dialer
	Throttle   time.Duration
	Reconnect  ReconnectConfig
	Logger     *slog.Logger
}

type priceObs struct {
	ts    time.Time
	price decimal.Decimal
}

const (
	priceHistoryWindow = time.Hour
	// minHistoryAge guards against false alarms after a backend restart:
	// if we only have ~5 minutes of price data and the price moved 5%
	// in that window, that's not "1h drop ≥5%" — it's a 5-minute spike
	// that happens to round to the threshold. Wait until we have at
	// least 30 min of observations before reporting change_pct_1h.
	minHistoryAge = 30 * time.Minute
)

type Collector struct {
	cfg          CollectorConfig
	dialer       Dialer
	logger       *slog.Logger
	mu           sync.Mutex
	lastEmit     map[string]time.Time
	priceHistory map[string][]priceObs
}

func NewCollector(cfg CollectorConfig) *Collector {
	if cfg.URL == "" {
		cfg.URL = defaultURL
	}
	if len(cfg.ProductIDs) == 0 {
		cfg.ProductIDs = []string{defaultProductBTC, defaultProductETH}
	}
	if cfg.Throttle <= 0 {
		cfg.Throttle = defaultThrottle
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}

	d := cfg.Dialer
	if d == nil {
		d = NewWSDialer(DialerConfig{URL: cfg.URL, ProductIDs: cfg.ProductIDs})
	}

	return &Collector{
		cfg:          cfg,
		dialer:       d,
		logger:       cfg.Logger,
		lastEmit:     make(map[string]time.Time),
		priceHistory: make(map[string][]priceObs),
	}
}

func (c *Collector) Name() string { return Name }

func (c *Collector) Run(ctx context.Context) error {
	err := Reconnect(ctx, c.dialer, c.cfg.Reconnect, c.handleConn)
	if err != nil && !errors.Is(err, context.Canceled) &&
		!errors.Is(err, context.DeadlineExceeded) {
		c.cfg.State.RecordError(ctx, Name, err.Error())
	}
	return err
}

func (c *Collector) handleConn(ctx context.Context, conn *Conn) error {
	seq := NewSequencer()
	agg := NewAggregator()
	count := int64(0)

	loopErr := ReadLoop(
		ctx,
		conn,
		seq,
		func(hctx context.Context, f Frame) error {
			switch f.Kind {
			case FrameTypeUnknown, FrameTypeSubscriptions, FrameTypeHeartbeats:
				return nil
			case FrameTypeTicker, FrameTypeSnapshot:
				ts := f.Timestamp.UTC()
				if ts.IsZero() {
					ts = time.Now().UTC()
				}
				for _, tk := range f.Tickers {
					tick := Tick{
						Symbol:    tk.ProductID,
						TS:        ts,
						Price:     tk.Price,
						Volume24h: tk.Volume24h,
					}
					if err := c.cfg.Repo.InsertTick(hctx, tick); err != nil {
						c.logger.Warn(
							"insert tick",
							"symbol",
							tick.Symbol,
							"err",
							err,
						)
						continue
					}
					if closed, _ := agg.Push(tick); closed != nil {
						if err := c.cfg.Repo.UpsertMinute(
							hctx,
							*closed,
						); err != nil {
							c.logger.Warn(
								"upsert minute",
								"symbol",
								closed.Symbol,
								"minute",
								closed.Minute,
								"err",
								err,
							)
						}
					}
					if c.shouldEmit(tick.Symbol) {
						c.emitTick(tick)
						count++
					}
				}
			}
			return nil
		},
	)

	c.logger.Info("coinbase loop exit",
		"err", loopErrString(loopErr),
		"emit_count", count,
		"agg_open", aggLen(agg),
	)
	if loopErr == nil || errors.Is(loopErr, ErrSequenceGap) {
		c.cfg.State.RecordSuccess(ctx, Name, count)
	}
	return loopErr
}

func loopErrString(err error) string {
	if err == nil {
		return "<nil>"
	}
	return err.Error()
}

func aggLen(a *Aggregator) int {
	if a == nil {
		return 0
	}
	return len(a.open)
}

func (c *Collector) shouldEmit(symbol string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	last, ok := c.lastEmit[symbol]
	now := time.Now()
	if !ok || now.Sub(last) >= c.cfg.Throttle {
		c.lastEmit[symbol] = now
		return true
	}
	return false
}

type tickPayload struct {
	Symbol      string          `json:"symbol"`
	TS          time.Time       `json:"ts"`
	Price       decimal.Decimal `json:"price"`
	Volume24h   decimal.Decimal `json:"volume_24h"`
	ChangePct1h *float64        `json:"change_pct_1h,omitempty"`
}

func (c *Collector) emitTick(t Tick) {
	c.recordPrice(t.Symbol, t.TS, t.Price)
	payload := tickPayload{
		Symbol:    t.Symbol,
		TS:        t.TS,
		Price:     t.Price,
		Volume24h: t.Volume24h,
	}
	if pct, ok := c.changePct1h(t.Symbol, t.TS, t.Price); ok {
		payload.ChangePct1h = &pct
	}
	body, _ := json.Marshal(payload)
	c.cfg.Emitter.Emit(events.Event{
		Topic:     events.TopicCoinbasePrice,
		Timestamp: t.TS,
		Source:    Name,
		Payload:   json.RawMessage(body),
	})
}

// recordPrice keeps a sliding 1-hour window of (timestamp, price)
// observations per symbol so we can compute trailing percentage change
// without hitting the database on every tick.
func (c *Collector) recordPrice(
	symbol string,
	ts time.Time,
	price decimal.Decimal,
) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cutoff := ts.Add(-priceHistoryWindow)
	hist := c.priceHistory[symbol]
	drop := 0
	for drop < len(hist) && hist[drop].ts.Before(cutoff) {
		drop++
	}
	hist = append(hist[drop:], priceObs{ts: ts, price: price})
	c.priceHistory[symbol] = hist
}

// changePct1h returns the percent change from the oldest observation in
// the sliding window to `current`. Returns false if we haven't yet seen
// minHistoryAge of data — predicates against early-life ticks would
// otherwise fire on noisy short windows. Used by the alerts engine via
// the emitted `change_pct_1h` field.
func (c *Collector) changePct1h(
	symbol string,
	currentTs time.Time,
	current decimal.Decimal,
) (float64, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	hist := c.priceHistory[symbol]
	if len(hist) == 0 {
		return 0, false
	}
	oldest := hist[0]
	if currentTs.Sub(oldest.ts) < minHistoryAge {
		return 0, false
	}
	if oldest.price.IsZero() {
		return 0, false
	}
	pct, _ := current.Sub(oldest.price).Div(oldest.price).Float64()
	return pct * 100, true
}
