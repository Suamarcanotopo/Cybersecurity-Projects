// ©AngelaMos | 2026
// store.go

package snapshot

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/redis/go-redis/v9"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	keyPrefix       = "state:"
	keyHashPrice    = "state:coinbase_price"
	scanCount       = 100
	wrongTypeMarker = "WRONGTYPE"
)

type Store struct {
	rdb *redis.Client
}

func NewStore(rdb *redis.Client) *Store { return &Store{rdb: rdb} }

func (s *Store) PutLatest(
	ctx context.Context,
	topic events.Topic,
	payload json.RawMessage,
) error {
	if err := s.rdb.Set(ctx, keyPrefix+string(topic), []byte(payload), 0).
		Err(); err != nil {
		return fmt.Errorf("redis set %s: %w", topic, err)
	}
	return nil
}

func (s *Store) MergeSymbolMap(
	ctx context.Context,
	topic events.Topic,
	payload json.RawMessage,
) error {
	var tick struct {
		Symbol string `json:"symbol"`
	}
	if err := json.Unmarshal(payload, &tick); err != nil || tick.Symbol == "" {
		return fmt.Errorf("coinbase merge: no symbol in payload")
	}

	key := keyPrefix + string(topic)
	err := s.rdb.HSet(ctx, key, tick.Symbol, []byte(payload)).Err()
	if err == nil {
		return nil
	}
	if !isWrongType(err) {
		return fmt.Errorf("redis hset %s/%s: %w", topic, tick.Symbol, err)
	}
	if delErr := s.rdb.Del(ctx, key).Err(); delErr != nil {
		return fmt.Errorf("redis del legacy %s: %w", key, delErr)
	}
	if err := s.rdb.HSet(ctx, key, tick.Symbol, []byte(payload)).
		Err(); err != nil {
		return fmt.Errorf(
			"redis hset %s/%s after migration: %w",
			topic,
			tick.Symbol,
			err,
		)
	}
	return nil
}

func isWrongType(err error) bool {
	return err != nil && strings.Contains(err.Error(), wrongTypeMarker)
}

func (s *Store) GetAll(
	ctx context.Context,
) (map[string]json.RawMessage, error) {
	out := map[string]json.RawMessage{}
	var cursor uint64
	for {
		keys, next, err := s.rdb.Scan(ctx, cursor, keyPrefix+"*", scanCount).
			Result()
		if err != nil {
			return nil, fmt.Errorf("scan state: %w", err)
		}
		for _, k := range keys {
			topic := k[len(keyPrefix):]
			val, err := s.readKey(ctx, k)
			if err != nil {
				continue
			}
			out[topic] = val
		}
		if next == 0 {
			break
		}
		cursor = next
	}
	return out, nil
}

func (s *Store) readKey(
	ctx context.Context,
	key string,
) (json.RawMessage, error) {
	t, err := s.rdb.Type(ctx, key).Result()
	if err != nil {
		return nil, err
	}
	switch t {
	case "string":
		v, err := s.rdb.Get(ctx, key).Bytes()
		if err != nil {
			return nil, err
		}
		return json.RawMessage(v), nil
	case "hash":
		fields, err := s.rdb.HGetAll(ctx, key).Result()
		if err != nil {
			return nil, err
		}
		m := make(map[string]json.RawMessage, len(fields))
		for k, v := range fields {
			m[k] = json.RawMessage(v)
		}
		return json.Marshal(m)
	}
	return nil, fmt.Errorf("unsupported redis type %q for key %s", t, key)
}
