// ©AngelaMos | 2026
// cached.go

package greynoise

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	cacheKeyPrefix = "gn:lookup:"
	cacheHitTTL    = 6 * time.Hour
	cacheMissTTL   = 30 * time.Minute
	cacheMissValue = "__miss__"
)

type Cached struct {
	inner *Client
	rdb   *redis.Client
}

func NewCached(inner *Client, rdb *redis.Client) *Cached {
	return &Cached{inner: inner, rdb: rdb}
}

func (c *Cached) Lookup(ctx context.Context, ip string) (Verdict, error) {
	key := cacheKeyPrefix + ip

	if c.rdb != nil {
		raw, err := c.rdb.Get(ctx, key).Result()
		if err == nil {
			if raw == cacheMissValue {
				return Verdict{}, ErrUnknownIP
			}
			var v Verdict
			if jerr := json.Unmarshal([]byte(raw), &v); jerr == nil {
				return v, nil
			}
		} else if !errors.Is(err, redis.Nil) {
			// Redis is degraded — fall through to live lookup. Don't cache
			// the result either since the cache layer is itself unhealthy.
			v, lerr := c.inner.Lookup(ctx, ip)
			return v, lerr
		}
	}

	v, err := c.inner.Lookup(ctx, ip)
	if err != nil {
		if errors.Is(err, ErrUnknownIP) && c.rdb != nil {
			_ = c.rdb.Set(ctx, key, cacheMissValue, cacheMissTTL).Err()
		}
		return Verdict{}, err
	}

	if c.rdb != nil {
		if payload, merr := json.Marshal(v); merr == nil {
			_ = c.rdb.Set(ctx, key, string(payload), cacheHitTTL).Err()
		}
	}
	return v, nil
}
