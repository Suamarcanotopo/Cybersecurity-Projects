// ©AngelaMos | 2026
// repo.go

package dshield

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
)

type Snapshot struct {
	TS      time.Time       `db:"ts"`
	Kind    string          `db:"kind"`
	Payload json.RawMessage `db:"payload"`
}

type Repo struct {
	db *sqlx.DB
}

func NewRepo(db *sqlx.DB) *Repo { return &Repo{db: db} }

func (r *Repo) PutSnapshot(
	ctx context.Context,
	ts time.Time,
	kind string,
	payload json.RawMessage,
) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO dshield_snapshots (ts, kind, payload)
		VALUES ($1, $2, $3)
		ON CONFLICT (ts, kind) DO UPDATE SET payload = EXCLUDED.payload`,
		ts, kind, []byte(payload),
	)
	if err != nil {
		return fmt.Errorf("put dshield snapshot %s: %w", kind, err)
	}
	return nil
}

func (r *Repo) LatestByKind(
	ctx context.Context,
	kind string,
	limit int,
) ([]Snapshot, error) {
	var rows []Snapshot
	err := r.db.SelectContext(ctx, &rows, `
		SELECT ts, kind, payload FROM dshield_snapshots
		 WHERE kind = $1
		 ORDER BY ts DESC LIMIT $2`, kind, limit)
	if err != nil {
		return nil, fmt.Errorf("latest dshield by kind: %w", err)
	}
	return rows, nil
}
