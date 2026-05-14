// ©AngelaMos | 2026
// handler.go

package ws

import (
	"net/http"
	"strings"
	"sync"
	"sync/atomic"

	cdrws "github.com/coder/websocket"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/middleware"
)

// defaultMaxConnsPerIP is permissive — a single user with React
// StrictMode in dev (effect runs twice), two tabs, and a brief reconnect
// race already burns ~6 simultaneous connections from one IP. The hub-
// level MaxSubscribers (default 5000) is the real DoS guard; this just
// blocks a single host from running thousands of sockets.
const defaultMaxConnsPerIP = 25

type HandlerConfig struct {
	Hub              *Hub
	MaxConnsPerIP    int
	TrustedProxyHops int
}

type Handler struct {
	hub              *Hub
	maxConnsPerIP    int
	trustedProxyHops int
	perIP            sync.Map
}

func NewHandler(hub *Hub) *Handler {
	return NewHandlerWithConfig(HandlerConfig{Hub: hub})
}

func NewHandlerWithConfig(cfg HandlerConfig) *Handler {
	if cfg.MaxConnsPerIP <= 0 {
		cfg.MaxConnsPerIP = defaultMaxConnsPerIP
	}
	return &Handler{
		hub:              cfg.Hub,
		maxConnsPerIP:    cfg.MaxConnsPerIP,
		trustedProxyHops: cfg.TrustedProxyHops,
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ip := middleware.ClientIP(r, h.trustedProxyHops)
	counter := h.counterFor(ip)
	if counter.Add(1) > int32(h.maxConnsPerIP) {
		counter.Add(-1)
		http.Error(w, "too many connections", http.StatusTooManyRequests)
		return
	}
	defer counter.Add(-1)

	c, err := cdrws.Accept(w, r, &cdrws.AcceptOptions{
		InsecureSkipVerify: false,
	})
	if err != nil {
		return
	}

	topics := parseTopics(r.URL.Query().Get("topics"))
	_ = h.hub.Serve(r.Context(), c, topics)
}

func (h *Handler) counterFor(ip string) *atomic.Int32 {
	if existing, ok := h.perIP.Load(ip); ok {
		if c, ok := existing.(*atomic.Int32); ok {
			return c
		}
	}
	fresh := &atomic.Int32{}
	actual, _ := h.perIP.LoadOrStore(ip, fresh)
	if c, ok := actual.(*atomic.Int32); ok {
		return c
	}
	return fresh
}

func parseTopics(raw string) []events.Topic {
	if raw == "" {
		return events.AllTopics()
	}
	parts := strings.Split(raw, ",")
	out := make([]events.Topic, 0, len(parts))
	for _, p := range parts {
		t := events.Topic(strings.TrimSpace(p))
		if t.IsValid() {
			out = append(out, t)
		}
	}
	if len(out) == 0 {
		return events.AllTopics()
	}
	return out
}
