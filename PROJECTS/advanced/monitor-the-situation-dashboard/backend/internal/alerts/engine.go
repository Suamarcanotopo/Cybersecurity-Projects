// ©AngelaMos | 2026
// engine.go

package alerts

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
	"github.com/redis/go-redis/v9"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

// Channel is the abstract destination an alert is sent to. Slack/Discord
// webhooks and Telegram bots all reduce to "send this text via this
// transport". The engine doesn't care about the specific kind — that's
// the Notifier's job.
type Channel struct {
	ID    string
	Type  string
	Label string
	// Decoded config — for slack/discord this is the webhook URL,
	// for telegram it's a (bot_token, chat_id) pair. The Notifier
	// implementation handles the type-specific details.
	WebhookURL string
	BotToken   string
	ChatID     int64
}

// Notifier is the transport for sending an alert. The notifications
// package implements one — this seam is here so tests can mock it.
type Notifier interface {
	SendAlert(ctx context.Context, ch Channel, message string) error
}

// ChannelLoader returns the configured destinations for a user. The
// notifications package decrypts channel configs on demand and produces
// these. Engine invokes it once per matching rule.
type ChannelLoader interface {
	LoadChannels(ctx context.Context, userID string) ([]Channel, error)
}

type CooldownStore interface {
	TryAcquire(ctx context.Context, key string, ttl time.Duration) (bool, error)
}

type EngineConfig struct {
	Repo       Repository
	Notifier   Notifier
	Loader     ChannelLoader
	Cooldowns  CooldownStore
	Logger     *slog.Logger
	ReloadTick time.Duration
}

type Engine struct {
	repo         Repository
	notifier     Notifier
	loader       ChannelLoader
	cooldowns    CooldownStore
	logger       *slog.Logger
	reloadTick   time.Duration
	celEnv       *cel.Env
	rulesByTopic atomic.Pointer[map[string][]compiledRule]
}

type compiledRule struct {
	rule    Rule
	program cel.Program
}

func NewEngine(cfg EngineConfig) (*Engine, error) {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	if cfg.ReloadTick <= 0 {
		cfg.ReloadTick = 30 * time.Second
	}
	env, err := cel.NewEnv(
		cel.Variable("event", cel.DynType),
	)
	if err != nil {
		return nil, fmt.Errorf("cel env: %w", err)
	}
	e := &Engine{
		repo:       cfg.Repo,
		notifier:   cfg.Notifier,
		loader:     cfg.Loader,
		cooldowns:  cfg.Cooldowns,
		logger:     logger,
		reloadTick: cfg.ReloadTick,
		celEnv:     env,
	}
	empty := map[string][]compiledRule{}
	e.rulesByTopic.Store(&empty)
	return e, nil
}

// RefreshLoop reloads rules from the database periodically. Cheap — the
// table is small (one user × ~6 default rules). Hot path stays in-memory.
func (e *Engine) RefreshLoop(ctx context.Context) error {
	if err := e.reload(ctx); err != nil {
		e.logger.Warn("alerts: initial reload failed", "err", err)
	}
	t := time.NewTicker(e.reloadTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			if err := e.reload(ctx); err != nil {
				e.logger.Warn("alerts: reload failed", "err", err)
			}
		}
	}
}

func (e *Engine) reload(ctx context.Context) error {
	all, err := e.repo.ListAll(ctx)
	if err != nil {
		return err
	}
	indexed := make(map[string][]compiledRule, len(all))
	for _, r := range all {
		prog, err := e.compile(r.Predicate)
		if err != nil {
			e.logger.Warn("alerts: skipping rule with bad predicate",
				"rule_id", r.ID, "topic", r.Topic, "err", err)
			continue
		}
		indexed[r.Topic] = append(
			indexed[r.Topic],
			compiledRule{rule: r, program: prog},
		)
	}
	e.rulesByTopic.Store(&indexed)
	return nil
}

func (e *Engine) compile(predicate string) (cel.Program, error) {
	if predicate == "" {
		// Empty predicate = always fire. Use a constant-true program so
		// the eval path is uniform.
		ast, iss := e.celEnv.Compile("true")
		if iss != nil && iss.Err() != nil {
			return nil, iss.Err()
		}
		return e.celEnv.Program(ast)
	}
	ast, iss := e.celEnv.Compile(predicate)
	if iss != nil && iss.Err() != nil {
		return nil, iss.Err()
	}
	return e.celEnv.Program(ast)
}

// Evaluate is the per-event hot path. Looks up rules indexed by topic,
// evaluates each predicate against the event payload, then for matches
// loads the user's channels and dispatches via the notifier. Cooldowns
// are per (rule, channel) so a critical Telegram alert and a less-
// critical Discord alert for the same rule have independent windows.
func (e *Engine) Evaluate(ctx context.Context, ev events.Event) {
	idx := e.rulesByTopic.Load()
	if idx == nil {
		return
	}
	rules, ok := (*idx)[string(ev.Topic)]
	if !ok || len(rules) == 0 {
		return
	}

	payload, err := normalizePayload(ev.Payload)
	if err != nil {
		e.logger.Warn(
			"alerts: payload normalize failed",
			"topic",
			ev.Topic,
			"err",
			err,
		)
		return
	}

	for _, cr := range rules {
		if !cr.rule.Enabled {
			continue
		}
		match, err := evalPredicate(cr.program, payload)
		if err != nil {
			e.logger.Warn("alerts: predicate eval failed",
				"rule_id", cr.rule.ID, "topic", ev.Topic, "err", err)
			continue
		}
		if !match {
			continue
		}
		e.fire(ctx, cr.rule, ev, payload)
	}
}

func (e *Engine) fire(
	ctx context.Context,
	rule Rule,
	ev events.Event,
	payload map[string]any,
) {
	channels, err := e.loader.LoadChannels(ctx, rule.UserID)
	if err != nil {
		e.logger.Warn("alerts: load channels failed",
			"rule_id", rule.ID, "user_id", rule.UserID, "err", err)
		return
	}
	if len(channels) == 0 {
		return
	}
	cooldown := time.Duration(rule.CooldownSec) * time.Second
	message := formatMessage(rule, ev, payload)

	delivered := []string{}
	deliveryErrs := map[string]string{}

	var wg sync.WaitGroup
	var mu sync.Mutex

	for _, ch := range channels {
		ch := ch
		key := fmt.Sprintf("alert_cooldown:%s:%s:%s", rule.ID, ch.Type, ch.ID)
		ok, err := e.cooldowns.TryAcquire(ctx, key, cooldown)
		if err != nil {
			e.logger.Warn("alerts: cooldown lookup failed",
				"rule_id", rule.ID, "channel", ch.ID, "err", err)
			continue
		}
		if !ok {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := e.notifier.SendAlert(ctx, ch, message)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				deliveryErrs[ch.ID] = err.Error()
				e.logger.Warn("alerts: deliver failed",
					"rule_id", rule.ID, "channel_type", ch.Type, "err", err)
				return
			}
			delivered = append(delivered, ch.ID)
		}()
	}
	wg.Wait()

	body, _ := json.Marshal(payload)
	errBody, _ := json.Marshal(deliveryErrs)
	if err := e.repo.RecordFire(ctx, HistoryRow{
		RuleID:         rule.ID,
		UserID:         rule.UserID,
		FiredAt:        time.Now().UTC(),
		Payload:        body,
		DeliveredTo:    delivered,
		DeliveryErrors: errBody,
	}); err != nil {
		e.logger.Warn(
			"alerts: record fire failed",
			"rule_id",
			rule.ID,
			"err",
			err,
		)
	}
}

func evalPredicate(program cel.Program, payload map[string]any) (bool, error) {
	out, _, err := program.Eval(map[string]any{"event": payload})
	if err != nil {
		return false, err
	}
	v, err := celBool(out)
	if err != nil {
		return false, err
	}
	return v, nil
}

func celBool(v ref.Val) (bool, error) {
	if v == nil {
		return false, nil
	}
	switch v.Type() {
	case types.BoolType:
		b, ok := v.Value().(bool)
		if !ok {
			return false, fmt.Errorf(
				"cel bool: unexpected concrete type %T",
				v.Value(),
			)
		}
		return b, nil
	default:
		return false, fmt.Errorf("cel result is not bool: %v", v.Type())
	}
}

// normalizePayload turns whatever the bus carries (map[string]any,
// json.RawMessage, struct, ...) into a map suitable for CEL. CEL needs
// a map for field access syntax like `event.kp` to work.
func normalizePayload(p any) (map[string]any, error) {
	if p == nil {
		return map[string]any{}, nil
	}
	if m, ok := p.(map[string]any); ok {
		return m, nil
	}
	if raw, ok := p.(json.RawMessage); ok {
		var out map[string]any
		if err := json.Unmarshal(raw, &out); err != nil {
			return nil, err
		}
		return out, nil
	}
	body, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func formatMessage(rule Rule, ev events.Event, payload map[string]any) string {
	body, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		body = []byte(fmt.Sprintf("%v", payload))
	}
	return fmt.Sprintf("[%s] %s\n\nTopic: %s\nFired: %s\n\n%s",
		rule.Name, ev.Source, ev.Topic, ev.Timestamp.UTC().Format(time.RFC3339),
		body,
	)
}

// RedisCooldown is a default CooldownStore using SET NX EX.
type RedisCooldown struct {
	rdb *redis.Client
}

func NewRedisCooldown(rdb *redis.Client) *RedisCooldown {
	return &RedisCooldown{rdb: rdb}
}

func (c *RedisCooldown) TryAcquire(
	ctx context.Context,
	key string,
	ttl time.Duration,
) (bool, error) {
	if ttl <= 0 {
		return true, nil
	}
	ok, err := c.rdb.SetNX(ctx, key, "1", ttl).Result()
	if err != nil {
		return false, err
	}
	return ok, nil
}
