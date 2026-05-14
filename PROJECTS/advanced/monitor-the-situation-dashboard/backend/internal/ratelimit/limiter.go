// ©AngelaMos | 2026
// limiter.go

package ratelimit

import (
	"context"
	"log/slog"
	"time"

	"github.com/sony/gobreaker/v2"
	"golang.org/x/time/rate"
)

type Config struct {
	Name                     string
	Rate                     rate.Limit
	Burst                    int
	ConsecutiveFailureBudget uint32
	BreakerTimeout           time.Duration
	OnStateChange            func(name string, from, to gobreaker.State)
}

type Limiter[T any] struct {
	name string
	rl   *rate.Limiter
	cb   *gobreaker.CircuitBreaker[T]
}

func New[T any](cfg Config) *Limiter[T] {
	if cfg.ConsecutiveFailureBudget == 0 {
		cfg.ConsecutiveFailureBudget = 5
	}
	if cfg.BreakerTimeout == 0 {
		cfg.BreakerTimeout = 30 * time.Second
	}
	settings := gobreaker.Settings{
		Name:    cfg.Name,
		Timeout: cfg.BreakerTimeout,
		ReadyToTrip: func(c gobreaker.Counts) bool {
			return c.ConsecutiveFailures >= cfg.ConsecutiveFailureBudget
		},
		OnStateChange: func(name string, from, to gobreaker.State) {
			slog.Warn("circuit breaker state change",
				"name", name, "from", from.String(), "to", to.String())
			if cfg.OnStateChange != nil {
				cfg.OnStateChange(name, from, to)
			}
		},
	}
	return &Limiter[T]{
		name: cfg.Name,
		rl:   rate.NewLimiter(cfg.Rate, cfg.Burst),
		cb:   gobreaker.NewCircuitBreaker[T](settings),
	}
}

func (l *Limiter[T]) Do(
	ctx context.Context,
	fn func(context.Context) (T, error),
) (T, error) {
	var zero T
	if err := l.rl.Wait(ctx); err != nil {
		return zero, err
	}
	return l.cb.Execute(func() (T, error) { return fn(ctx) })
}

func (l *Limiter[T]) AdjustRate(newRate rate.Limit) {
	l.rl.SetLimit(newRate)
}

func (l *Limiter[T]) Name() string { return l.name }
