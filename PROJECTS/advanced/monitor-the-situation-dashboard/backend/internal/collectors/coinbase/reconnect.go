// ©AngelaMos | 2026
// reconnect.go

package coinbase

import (
	"context"
	"errors"
	"time"

	"github.com/cenkalti/backoff/v4"
)

const (
	defaultReconnectInitial = time.Second
	defaultReconnectMax     = 60 * time.Second
)

type ReconnectConfig struct {
	InitialInterval time.Duration
	MaxInterval     time.Duration
}

type ConnHandler func(ctx context.Context, conn *Conn) error

func PermanentReconnectError(err error) error {
	return backoff.Permanent(err)
}

func Reconnect(
	ctx context.Context,
	d Dialer,
	cfg ReconnectConfig,
	handler ConnHandler,
) error {
	if cfg.InitialInterval <= 0 {
		cfg.InitialInterval = defaultReconnectInitial
	}
	if cfg.MaxInterval <= 0 {
		cfg.MaxInterval = defaultReconnectMax
	}

	bo := backoff.NewExponentialBackOff()
	bo.InitialInterval = cfg.InitialInterval
	bo.MaxInterval = cfg.MaxInterval
	bo.MaxElapsedTime = 0

	op := func() error {
		if ctx.Err() != nil {
			return backoff.Permanent(ctx.Err())
		}
		conn, err := d.Dial(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return backoff.Permanent(ctx.Err())
			}
			return err
		}
		hErr := handler(ctx, conn)
		_ = conn.Close()
		if hErr == nil {
			return nil
		}
		var perm *backoff.PermanentError
		if errors.As(hErr, &perm) {
			return hErr
		}
		if ctx.Err() != nil {
			return backoff.Permanent(ctx.Err())
		}
		return hErr
	}

	return backoff.Retry(op, backoff.WithContext(bo, ctx))
}
