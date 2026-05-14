// ©AngelaMos | 2026
// repository.go

package alerts

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
)

type Repository interface {
	ListAll(ctx context.Context) ([]Rule, error)
	ListByUser(ctx context.Context, userID string) ([]Rule, error)
	Get(ctx context.Context, id, userID string) (*Rule, error)
	Create(ctx context.Context, r *Rule) error
	Update(ctx context.Context, r *Rule) error
	Delete(ctx context.Context, id, userID string) error
	SeedDefaults(ctx context.Context, userID string) error
	RecordFire(ctx context.Context, h HistoryRow) error
	RecentHistory(
		ctx context.Context,
		userID string,
		limit int,
	) ([]HistoryRow, error)
}

type repository struct {
	db core.DBTX
}

func NewRepository(db core.DBTX) Repository {
	return &repository{db: db}
}

func (r *repository) ListAll(ctx context.Context) ([]Rule, error) {
	var rules []Rule
	err := r.db.SelectContext(ctx, &rules, `
		SELECT id, user_id, name, topic, predicate, cooldown_sec, enabled, created_at, updated_at
		  FROM alert_rules
		 WHERE enabled = true`)
	if err != nil {
		return nil, fmt.Errorf("alerts list all: %w", err)
	}
	return rules, nil
}

func (r *repository) ListByUser(
	ctx context.Context,
	userID string,
) ([]Rule, error) {
	var rules []Rule
	err := r.db.SelectContext(ctx, &rules, `
		SELECT id, user_id, name, topic, predicate, cooldown_sec, enabled, created_at, updated_at
		  FROM alert_rules
		 WHERE user_id = $1
		 ORDER BY topic, name`, userID)
	if err != nil {
		return nil, fmt.Errorf("alerts list user: %w", err)
	}
	return rules, nil
}

func (r *repository) Get(
	ctx context.Context,
	id, userID string,
) (*Rule, error) {
	var rule Rule
	err := r.db.GetContext(ctx, &rule, `
		SELECT id, user_id, name, topic, predicate, cooldown_sec, enabled, created_at, updated_at
		  FROM alert_rules
		 WHERE id = $1 AND user_id = $2`, id, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("alerts get: %w", core.ErrNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("alerts get: %w", err)
	}
	return &rule, nil
}

func (r *repository) Create(ctx context.Context, rule *Rule) error {
	if rule.ID == "" {
		rule.ID = uuid.New().String()
	}
	err := r.db.GetContext(
		ctx,
		&rule.CreatedAt,
		`
		INSERT INTO alert_rules (id, user_id, name, topic, predicate, cooldown_sec, enabled)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING created_at`,
		rule.ID,
		rule.UserID,
		rule.Name,
		rule.Topic,
		rule.Predicate,
		rule.CooldownSec,
		rule.Enabled,
	)
	if err != nil {
		return fmt.Errorf("alerts create: %w", err)
	}
	rule.UpdatedAt = rule.CreatedAt
	return nil
}

func (r *repository) Update(ctx context.Context, rule *Rule) error {
	res, err := r.db.ExecContext(
		ctx,
		`
		UPDATE alert_rules
		   SET name         = $3,
		       predicate    = $4,
		       cooldown_sec = $5,
		       enabled      = $6,
		       updated_at   = NOW()
		 WHERE id = $1 AND user_id = $2`,
		rule.ID,
		rule.UserID,
		rule.Name,
		rule.Predicate,
		rule.CooldownSec,
		rule.Enabled,
	)
	if err != nil {
		return fmt.Errorf("alerts update: %w", err)
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("alerts update: %w", err)
	}
	if rows == 0 {
		return fmt.Errorf("alerts update: %w", core.ErrNotFound)
	}
	return nil
}

func (r *repository) Delete(ctx context.Context, id, userID string) error {
	res, err := r.db.ExecContext(ctx,
		`DELETE FROM alert_rules WHERE id = $1 AND user_id = $2`, id, userID)
	if err != nil {
		return fmt.Errorf("alerts delete: %w", err)
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("alerts delete: %w", err)
	}
	if rows == 0 {
		return fmt.Errorf("alerts delete: %w", core.ErrNotFound)
	}
	return nil
}

// SeedDefaults inserts the default rule set for a user, skipping rules
// they already have. Dedup is by (user_id, name) — not (user_id, topic) —
// so multiple defaults can target the same topic. BTC and ETH both fire
// on `coinbase_price`, and the original (user_id, topic) check would
// have inserted only the first one. Idempotent: safe to call on every
// login, which is how existing accounts pick up newly-added defaults.
func (r *repository) SeedDefaults(ctx context.Context, userID string) error {
	for _, def := range Defaults() {
		_, err := r.db.ExecContext(
			ctx,
			`
			INSERT INTO alert_rules (id, user_id, name, topic, predicate, cooldown_sec, enabled)
			SELECT $1, $2, $3, $4, $5, $6, true
			 WHERE NOT EXISTS (
				 SELECT 1 FROM alert_rules WHERE user_id = $2 AND name = $3
			 )`,
			uuid.New().
				String(),
			userID,
			def.Name,
			def.Topic,
			def.Predicate,
			def.CooldownSec,
		)
		if err != nil {
			return fmt.Errorf("seed default %s: %w", def.Name, err)
		}
	}
	return nil
}

func (r *repository) RecordFire(ctx context.Context, h HistoryRow) error {
	if h.FiredAt.IsZero() {
		h.FiredAt = time.Now().UTC()
	}
	if len(h.Payload) == 0 {
		h.Payload = json.RawMessage("{}")
	}
	delivered := pq.StringArray(h.DeliveredTo)
	_, err := r.db.ExecContext(
		ctx,
		`
		INSERT INTO alert_history (rule_id, user_id, fired_at, payload, delivered_to, delivery_errors)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		h.RuleID,
		h.UserID,
		h.FiredAt,
		[]byte(h.Payload),
		delivered,
		[]byte(h.DeliveryErrors),
	)
	if err != nil {
		return fmt.Errorf("alerts record fire: %w", err)
	}
	return nil
}

func (r *repository) RecentHistory(
	ctx context.Context,
	userID string,
	limit int,
) ([]HistoryRow, error) {
	if limit <= 0 {
		limit = 50
	}
	var rows []HistoryRow
	err := r.db.SelectContext(ctx, &rows, `
		SELECT id, rule_id, user_id, fired_at, payload, delivered_to, delivery_errors
		  FROM alert_history
		 WHERE user_id = $1
		 ORDER BY fired_at DESC
		 LIMIT $2`, userID, limit)
	if err != nil {
		return nil, fmt.Errorf("alerts recent history: %w", err)
	}
	return rows, nil
}
