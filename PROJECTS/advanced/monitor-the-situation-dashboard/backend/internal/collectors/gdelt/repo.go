// ©AngelaMos | 2026
// repo.go

package gdelt

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
)

const (
	sourceGDELTSpike = "gdelt_spike"
)

type SpikeRow struct {
	ID         string
	Theme      string
	OccurredAt time.Time
	Headline   string
	Payload    json.RawMessage
}

type Repo struct {
	db *sqlx.DB
}

func NewRepo(db *sqlx.DB) *Repo { return &Repo{db: db} }

func (r *Repo) Insert(ctx context.Context, row SpikeRow) (bool, error) {
	var id string
	err := r.db.GetContext(
		ctx,
		&id,
		`
		INSERT INTO world_events (id, source, occurred_at, headline, payload)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (id) DO NOTHING
		RETURNING id`,
		row.ID,
		sourceGDELTSpike,
		row.OccurredAt,
		row.Headline,
		[]byte(row.Payload),
	)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("insert gdelt spike %s: %w", row.ID, err)
	}
	return true, nil
}
