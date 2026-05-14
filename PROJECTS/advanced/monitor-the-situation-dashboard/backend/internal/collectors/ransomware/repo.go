// ©AngelaMos | 2026
// repo.go

package ransomware

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/lib/pq"
)

type Row struct {
	ID           string          `db:"id"`
	PostTitle    string          `db:"post_title"`
	GroupName    string          `db:"group_name"`
	DiscoveredAt time.Time       `db:"discovered_at"`
	Country      string          `db:"country"`
	Sector       string          `db:"sector"`
	Payload      json.RawMessage `db:"payload"`
}

type Repo struct {
	db *sqlx.DB
}

func NewRepo(db *sqlx.DB) *Repo { return &Repo{db: db} }

func (r *Repo) Insert(ctx context.Context, row Row) error {
	_, err := r.db.ExecContext(
		ctx,
		`
		INSERT INTO ransomware_victims
			(id, post_title, group_name, discovered_at, country, sector, payload)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (id) DO NOTHING`,
		row.ID,
		row.PostTitle,
		row.GroupName,
		row.DiscoveredAt,
		row.Country,
		row.Sector,
		[]byte(row.Payload),
	)
	if err != nil {
		return fmt.Errorf("insert ransom %s: %w", row.ID, err)
	}
	return nil
}

func (r *Repo) KnownIDs(
	ctx context.Context,
	ids []string,
) (map[string]bool, error) {
	if len(ids) == 0 {
		return map[string]bool{}, nil
	}
	var found []string
	if err := r.db.SelectContext(
		ctx,
		&found,
		`SELECT id FROM ransomware_victims WHERE id = ANY($1::text[])`,
		pq.Array(ids),
	); err != nil {
		return nil, fmt.Errorf("ransom known ids: %w", err)
	}
	out := make(map[string]bool, len(found))
	for _, id := range found {
		out[id] = true
	}
	return out, nil
}

func (r *Repo) Recent(ctx context.Context, limit int) ([]Row, error) {
	if limit <= 0 {
		limit = 50
	}
	var rows []Row
	err := r.db.SelectContext(ctx, &rows, `
		SELECT id, post_title, group_name, discovered_at, country, sector, payload
		  FROM ransomware_victims
		 ORDER BY discovered_at DESC
		 LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("recent ransomware: %w", err)
	}
	return rows, nil
}
