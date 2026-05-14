// ©AngelaMos | 2026
// client.go

package coinbase

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/shopspring/decimal"
)

const (
	defaultProductBTC     = "BTC-USD"
	defaultProductETH     = "ETH-USD"
	channelTicker         = "ticker"
	channelHeartbeats     = "heartbeats"
	channelSubscriptions  = "subscriptions"
	subscribeWriteTimeout = 5 * time.Second
	defaultReadFrameSize  = 1 << 20
)

type FrameType int

const (
	FrameTypeUnknown FrameType = iota
	FrameTypeSubscriptions
	FrameTypeTicker
	FrameTypeSnapshot
	FrameTypeHeartbeats
)

type TickerEntry struct {
	ProductID string          `json:"product_id"`
	Price     decimal.Decimal `json:"price"`
	Volume24h decimal.Decimal `json:"volume_24_h"`
	Time      time.Time       `json:"time"`
}

type Frame struct {
	Kind          FrameType
	SequenceNum   int64
	Timestamp     time.Time
	Tickers       []TickerEntry
	HeartbeatTime time.Time
}

type DialerConfig struct {
	URL          string
	ProductIDs   []string
	WriteTimeout time.Duration
	ReadFrameMax int64
}

type Dialer interface {
	Dial(ctx context.Context) (*Conn, error)
}

type WSDialer struct {
	cfg DialerConfig
}

func NewWSDialer(cfg DialerConfig) *WSDialer {
	if len(cfg.ProductIDs) == 0 {
		cfg.ProductIDs = []string{defaultProductBTC, defaultProductETH}
	}
	if cfg.WriteTimeout <= 0 {
		cfg.WriteTimeout = subscribeWriteTimeout
	}
	if cfg.ReadFrameMax <= 0 {
		cfg.ReadFrameMax = defaultReadFrameSize
	}
	return &WSDialer{cfg: cfg}
}

func (d *WSDialer) Dial(ctx context.Context) (*Conn, error) {
	c, _, err := websocket.Dial(ctx, d.cfg.URL, nil)
	if err != nil {
		return nil, fmt.Errorf("dial coinbase ws: %w", err)
	}
	c.SetReadLimit(d.cfg.ReadFrameMax)

	conn := &Conn{c: c}
	subCtx, cancel := context.WithTimeout(ctx, d.cfg.WriteTimeout)
	defer cancel()
	if err := conn.subscribe(
		subCtx,
		channelTicker,
		d.cfg.ProductIDs,
	); err != nil {
		_ = c.Close(websocket.StatusInternalError, "subscribe ticker")
		return nil, err
	}
	if err := conn.subscribe(subCtx, channelHeartbeats, nil); err != nil {
		_ = c.Close(websocket.StatusInternalError, "subscribe heartbeats")
		return nil, err
	}
	return conn, nil
}

type Conn struct {
	c *websocket.Conn
}

func (c *Conn) Close() error {
	if c == nil || c.c == nil {
		return nil
	}
	return c.c.Close(websocket.StatusNormalClosure, "")
}

type subscribeMsg struct {
	Type       string   `json:"type"`
	Channel    string   `json:"channel"`
	ProductIDs []string `json:"product_ids,omitempty"`
}

func (c *Conn) subscribe(
	ctx context.Context,
	channel string,
	productIDs []string,
) error {
	msg := subscribeMsg{
		Type:       "subscribe",
		Channel:    channel,
		ProductIDs: productIDs,
	}
	body, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal subscribe %s: %w", channel, err)
	}
	if err := c.c.Write(ctx, websocket.MessageText, body); err != nil {
		return fmt.Errorf("write subscribe %s: %w", channel, err)
	}
	return nil
}

type rawEnvelope struct {
	Channel     string          `json:"channel"`
	SequenceNum int64           `json:"sequence_num"`
	Timestamp   time.Time       `json:"timestamp"`
	Events      []rawEnvelopeEv `json:"events"`
}

type rawEnvelopeEv struct {
	Type        string        `json:"type"`
	Tickers     []TickerEntry `json:"tickers,omitempty"`
	CurrentTime string        `json:"current_time,omitempty"`
}

func parseCoinbaseTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t
	}
	if idx := strings.Index(s, " m=+"); idx > 0 {
		s = s[:idx]
	}
	if t, err := time.Parse(
		"2006-01-02 15:04:05.999999999 -0700 MST",
		s,
	); err == nil {
		return t
	}
	return time.Time{}
}

var ErrFrameMalformed = errors.New("coinbase: malformed frame")

func (c *Conn) ReadFrame(ctx context.Context) (Frame, error) {
	_, msg, err := c.c.Read(ctx)
	if err != nil {
		return Frame{}, fmt.Errorf("read coinbase frame: %w", err)
	}
	return decodeFrame(msg)
}

func decodeFrame(msg []byte) (Frame, error) {
	var env rawEnvelope
	if err := json.Unmarshal(msg, &env); err != nil {
		return Frame{}, fmt.Errorf("%w: %w", ErrFrameMalformed, err)
	}

	frame := Frame{
		SequenceNum: env.SequenceNum,
		Timestamp:   env.Timestamp,
	}

	switch env.Channel {
	case channelSubscriptions:
		frame.Kind = FrameTypeSubscriptions
		return frame, nil

	case channelHeartbeats:
		frame.Kind = FrameTypeHeartbeats
		if len(env.Events) > 0 {
			frame.HeartbeatTime = parseCoinbaseTime(env.Events[0].CurrentTime)
		}
		return frame, nil

	case channelTicker:
		for _, ev := range env.Events {
			frame.Tickers = append(frame.Tickers, ev.Tickers...)
			if ev.Type == "snapshot" {
				frame.Kind = FrameTypeSnapshot
			}
		}
		if frame.Kind != FrameTypeSnapshot {
			frame.Kind = FrameTypeTicker
		}
		return frame, nil
	}

	frame.Kind = FrameTypeUnknown
	return frame, nil
}
