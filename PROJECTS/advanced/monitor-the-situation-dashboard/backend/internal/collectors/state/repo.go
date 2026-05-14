// ©AngelaMos | 2026
// repo.go

package state

import (
	"context"
	"log/slog"
	"time"

	"github.com/jmoiron/sqlx"
)

type CollectorState string

const (
	StateHealthy  CollectorState = "healthy"
	StateDegraded CollectorState = "degraded"
)

type Row struct {
	Name           string         `db:"name"`
	State          CollectorState `db:"state"`
	LastSuccessAt  *time.Time     `db:"last_success_at"`
	LastErrorAt    *time.Time     `db:"last_error_at"`
	LastError      string         `db:"last_error"`
	LastEventCount int64          `db:"last_event_count"`
	UpdatedAt      time.Time      `db:"updated_at"`
}

type Repo struct {
	db     *sqlx.DB
	logger *slog.Logger
}

func NewRepo(db *sqlx.DB) *Repo {
	return &Repo{db: db, logger: slog.Default()}
}

func NewRepoWithLogger(db *sqlx.DB, logger *slog.Logger) *Repo {
	if logger == nil {
		logger = slog.Default()
	}
	return &Repo{db: db, logger: logger}
}

func (r *Repo) RecordSuccess(
	ctx context.Context,
	name string,
	eventCount int64,
) {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO collector_state (name, state, last_success_at, last_event_count, updated_at)
		VALUES ($1, $2, now(), $3, now())
		ON CONFLICT (name) DO UPDATE SET
			state            = EXCLUDED.state,
			last_success_at  = EXCLUDED.last_success_at,
			last_event_count = collector_state.last_event_count + EXCLUDED.last_event_count,
			updated_at       = EXCLUDED.updated_at`,
		name, StateHealthy, eventCount,
	)
	if err != nil {
		r.logger.Warn("collector_state record success failed",
			"collector", name, "err", err)
	}
}

func (r *Repo) RecordError(ctx context.Context, name, errMsg string) {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO collector_state (name, state, last_error_at, last_error, updated_at)
		VALUES ($1, $2, now(), $3, now())
		ON CONFLICT (name) DO UPDATE SET
			state         = EXCLUDED.state,
			last_error_at = EXCLUDED.last_error_at,
			last_error    = EXCLUDED.last_error,
			updated_at    = EXCLUDED.updated_at`,
		name, StateDegraded, errMsg,
	)
	if err != nil {
		r.logger.Warn("collector_state record error failed",
			"collector", name, "err", err)
	}
}

func (r *Repo) Get(ctx context.Context, name string) (Row, bool, error) {
	var row Row
	err := r.db.GetContext(ctx, &row, `
		SELECT name, state, last_success_at, last_error_at, last_error,
		       last_event_count, updated_at
		  FROM collector_state WHERE name = $1`, name)
	if err != nil {
		return Row{}, false, err
	}
	return row, true, nil
}

func (r *Repo) All(ctx context.Context) ([]Row, error) {
	var rows []Row
	err := r.db.SelectContext(ctx, &rows, `
		SELECT name, state, last_success_at, last_error_at, last_error,
		       last_event_count, updated_at
		  FROM collector_state ORDER BY name`)
	if err != nil {
		return nil, err
	}
	return rows, nil
}
