// ©AngelaMos | 2026
// hub.go

package ws

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"

	cdrws "github.com/coder/websocket"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	// Per-connection outbound buffer. Must absorb peak event rate ×
	// browser stutter window: heartbeat (5s) + coinbase (~8/s peak) +
	// ISS (10s) + occasional bursts of CVE/KEV/ransomware. 16 is too
	// small — a single browser GC pause fills it and triggers slow-
	// consumer close, which the user sees as "NO SIGNAL".
	defaultSubscriberBuf = 256
	defaultPingInterval  = 30 * time.Second
	defaultPingTimeout   = 10 * time.Second
	defaultWriteTimeout  = 5 * time.Second
	defaultMaxSubs       = 5000
)

// ErrAtCapacity signals the hub has reached MaxSubscribers and refuses
// to accept new connections.
var ErrAtCapacity = errors.New("ws hub at capacity")

type HubConfig struct {
	SubscriberBufferSize int
	PingInterval         time.Duration
	PingTimeout          time.Duration
	WriteTimeout         time.Duration
	MaxSubscribers       int
	Logger               *slog.Logger
}

type Hub struct {
	mu             sync.Mutex
	subs           map[*subscriber]struct{}
	bufSize        int
	pingInterval   time.Duration
	pingTimeout    time.Duration
	writeTimeout   time.Duration
	maxSubscribers int
	logger         *slog.Logger
}

func NewHub(cfg HubConfig) *Hub {
	if cfg.SubscriberBufferSize <= 0 {
		cfg.SubscriberBufferSize = defaultSubscriberBuf
	}
	if cfg.PingInterval <= 0 {
		cfg.PingInterval = defaultPingInterval
	}
	if cfg.PingTimeout <= 0 {
		cfg.PingTimeout = defaultPingTimeout
	}
	if cfg.WriteTimeout <= 0 {
		cfg.WriteTimeout = defaultWriteTimeout
	}
	if cfg.MaxSubscribers <= 0 {
		cfg.MaxSubscribers = defaultMaxSubs
	}
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Hub{
		subs:           make(map[*subscriber]struct{}),
		bufSize:        cfg.SubscriberBufferSize,
		pingInterval:   cfg.PingInterval,
		pingTimeout:    cfg.PingTimeout,
		writeTimeout:   cfg.WriteTimeout,
		maxSubscribers: cfg.MaxSubscribers,
		logger:         logger,
	}
}

func (h *Hub) Broadcast(topic events.Topic, payload []byte) {
	env, err := EncodeEnvelope(string(topic), payload)
	if err != nil {
		h.logger.Error("encode envelope", "err", err, "topic", topic)
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for sub := range h.subs {
		if _, ok := sub.topics[topic]; !ok {
			continue
		}
		select {
		case sub.msgs <- env:
		default:
			go sub.closeSlow()
		}
	}
}

func (h *Hub) Serve(
	ctx context.Context,
	c *cdrws.Conn,
	topics []events.Topic,
) error {
	sub := newSubscriber(topics, h.bufSize, func() {
		_ = c.Close(cdrws.StatusPolicyViolation, "slow consumer")
	})
	if !h.add(sub) {
		_ = c.Close(cdrws.StatusTryAgainLater, "server at capacity")
		return ErrAtCapacity
	}
	defer h.remove(sub)

	// Drain client→server messages without closing on receive. The
	// dashboard's WS protocol is currently server-push only (server
	// broadcasts, client listens), but the frontend's setReady() handshake
	// sends a `{"op":"init"}` line. The previous c.CloseRead(ctx) call
	// killed the connection with StatusPolicyViolation on receiving any
	// data message — turning every client init into a forced disconnect
	// and reconnect-loop. This loop reads and discards instead, leaving
	// ping/pong + close frames intact.
	connCtx, cancelRead := context.WithCancel(ctx)
	defer cancelRead()
	go func() {
		for {
			if _, _, err := c.Read(connCtx); err != nil {
				cancelRead()
				return
			}
		}
	}()
	pingT := time.NewTicker(h.pingInterval)
	defer pingT.Stop()

	for {
		select {
		case msg := <-sub.msgs:
			wctx, cancel := context.WithTimeout(connCtx, h.writeTimeout)
			err := c.Write(wctx, cdrws.MessageText, msg)
			cancel()
			if err != nil {
				return err
			}
		case <-pingT.C:
			pctx, cancel := context.WithTimeout(connCtx, h.pingTimeout)
			err := c.Ping(pctx)
			cancel()
			if err != nil {
				return err
			}
		case <-connCtx.Done():
			_ = c.Close(cdrws.StatusNormalClosure, "")
			return connCtx.Err()
		}
	}
}

func (h *Hub) add(sub *subscriber) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.subs) >= h.maxSubscribers {
		return false
	}
	h.subs[sub] = struct{}{}
	return true
}

func (h *Hub) remove(sub *subscriber) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.subs, sub)
}

func (h *Hub) SubscriberCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs)
}
