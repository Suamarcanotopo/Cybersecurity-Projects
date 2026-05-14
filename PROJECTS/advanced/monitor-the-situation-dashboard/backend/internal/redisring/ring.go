// ©AngelaMos | 2026
// ring.go

package redisring

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	defaultRetention = 24 * time.Hour
)

type Config struct {
	Retention time.Duration
}

type Client struct {
	rc        *redis.Client
	retention time.Duration
}

func New(rc *redis.Client, cfg Config) *Client {
	if cfg.Retention <= 0 {
		cfg.Retention = defaultRetention
	}
	return &Client{rc: rc, retention: cfg.Retention}
}

func (c *Client) Push(
	ctx context.Context,
	key string,
	score int64,
	payload []byte,
) error {
	cutoff := time.UnixMilli(score).Add(-c.retention).UnixMilli()
	pipe := c.rc.Pipeline()
	pipe.ZAdd(ctx, key, redis.Z{Score: float64(score), Member: payload})
	pipe.ZRemRangeByScore(ctx, key, "-inf", "("+strconv.FormatInt(cutoff, 10))
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("ring push %s @ %d: %w", key, score, err)
	}
	return nil
}

func (c *Client) Recent(
	ctx context.Context,
	key string,
	n int,
) ([][]byte, error) {
	if n <= 0 {
		return nil, nil
	}
	res, err := c.rc.ZRevRangeByScore(ctx, key, &redis.ZRangeBy{
		Min:    "-inf",
		Max:    "+inf",
		Offset: 0,
		Count:  int64(n),
	}).Result()
	if err != nil {
		return nil, fmt.Errorf("ring recent %s: %w", key, err)
	}
	out := make([][]byte, 0, len(res))
	for _, s := range res {
		out = append(out, []byte(s))
	}
	return out, nil
}

func (c *Client) Range(
	ctx context.Context,
	key string,
	fromScore, toScore int64,
) ([][]byte, error) {
	res, err := c.rc.ZRangeByScore(ctx, key, &redis.ZRangeBy{
		Min: strconv.FormatInt(fromScore, 10),
		Max: strconv.FormatInt(toScore, 10),
	}).Result()
	if err != nil {
		return nil, fmt.Errorf("ring range %s: %w", key, err)
	}
	out := make([][]byte, 0, len(res))
	for _, s := range res {
		out = append(out, []byte(s))
	}
	return out, nil
}
