// ©AngelaMos | 2026
// tle_store.go

package iss

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	tleKey = "iss:tle"
	tleTTL = 24 * time.Hour
)

type TLEStore struct {
	rdb *redis.Client
}

func NewTLEStore(rdb *redis.Client) *TLEStore {
	return &TLEStore{rdb: rdb}
}

func (s *TLEStore) Save(ctx context.Context, tle TLE) error {
	body, err := json.Marshal(tle)
	if err != nil {
		return fmt.Errorf("marshal tle: %w", err)
	}
	if err := s.rdb.Set(ctx, tleKey, body, tleTTL).Err(); err != nil {
		return fmt.Errorf("save iss tle: %w", err)
	}
	return nil
}

func (s *TLEStore) Load(ctx context.Context) (TLE, bool, error) {
	body, err := s.rdb.Get(ctx, tleKey).Bytes()
	if errors.Is(err, redis.Nil) {
		return TLE{}, false, nil
	}
	if err != nil {
		return TLE{}, false, fmt.Errorf("load iss tle: %w", err)
	}
	var tle TLE
	if err := json.Unmarshal(body, &tle); err != nil {
		return TLE{}, false, fmt.Errorf("unmarshal tle: %w", err)
	}
	return tle, true, nil
}
