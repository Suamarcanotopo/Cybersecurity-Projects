// ©AngelaMos | 2026
// repo.go

package wikipedia

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/redis/go-redis/v9"
)

const (
	keyRevID      = "wiki:itn:revid"
	sourceWikiITN = "wiki_itn"
)

type Entry struct {
	ID         string
	Headline   string
	OccurredAt time.Time
	Payload    json.RawMessage
}

type Repo struct {
	db  *sqlx.DB
	rdb *redis.Client
}

func NewRepo(db *sqlx.DB, rdb *redis.Client) *Repo {
	return &Repo{db: db, rdb: rdb}
}

func (r *Repo) RememberRevID(ctx context.Context, revID int64) error {
	if err := r.rdb.Set(ctx, keyRevID, strconv.FormatInt(revID, 10), 0).
		Err(); err != nil {
		return fmt.Errorf("save wiki revid: %w", err)
	}
	return nil
}

func (r *Repo) LastRevID(ctx context.Context) (int64, bool, error) {
	s, err := r.rdb.Get(ctx, keyRevID).Result()
	if errors.Is(err, redis.Nil) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, fmt.Errorf("load wiki revid: %w", err)
	}
	rev, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, false, fmt.Errorf("parse wiki revid %q: %w", s, err)
	}
	return rev, true, nil
}

func (r *Repo) Insert(ctx context.Context, e Entry) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO world_events (id, source, occurred_at, headline, payload)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (id) DO NOTHING`,
		e.ID, sourceWikiITN, e.OccurredAt, e.Headline, []byte(e.Payload),
	)
	if err != nil {
		return fmt.Errorf("insert wiki event %s: %w", e.ID, err)
	}
	return nil
}
