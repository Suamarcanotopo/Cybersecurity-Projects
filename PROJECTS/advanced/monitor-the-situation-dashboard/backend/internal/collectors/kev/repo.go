// ©AngelaMos | 2026
// repo.go

package kev

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/lib/pq"
)

type Row struct {
	CveID             string          `db:"cve_id"`
	Vendor            string          `db:"vendor"`
	Product           string          `db:"product"`
	VulnerabilityName string          `db:"vulnerability_name"`
	DateAdded         time.Time       `db:"date_added"`
	DueDate           *time.Time      `db:"due_date"`
	RansomwareUse     string          `db:"ransomware_use"`
	Payload           json.RawMessage `db:"payload"`
}

type Repo struct {
	db *sqlx.DB
}

func NewRepo(db *sqlx.DB) *Repo { return &Repo{db: db} }

func (r *Repo) Insert(ctx context.Context, row Row) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO kev_entries
			(cve_id, vendor, product, vulnerability_name, date_added, due_date, ransomware_use, payload)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (cve_id) DO UPDATE SET
			vendor             = EXCLUDED.vendor,
			product            = EXCLUDED.product,
			vulnerability_name = EXCLUDED.vulnerability_name,
			date_added         = EXCLUDED.date_added,
			due_date           = EXCLUDED.due_date,
			ransomware_use     = EXCLUDED.ransomware_use,
			payload            = EXCLUDED.payload`,
		row.CveID, row.Vendor, row.Product, row.VulnerabilityName,
		row.DateAdded, row.DueDate, row.RansomwareUse, []byte(row.Payload),
	)
	if err != nil {
		return fmt.Errorf("insert kev %s: %w", row.CveID, err)
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
		`SELECT cve_id FROM kev_entries WHERE cve_id = ANY($1::text[])`,
		pq.Array(ids),
	); err != nil {
		return nil, fmt.Errorf("kev known ids: %w", err)
	}
	out := make(map[string]bool, len(found))
	for _, id := range found {
		out[id] = true
	}
	return out, nil
}

func (r *Repo) Count(ctx context.Context) (int64, error) {
	var n int64
	if err := r.db.GetContext(
		ctx,
		&n,
		`SELECT count(*) FROM kev_entries`,
	); err != nil {
		return 0, fmt.Errorf("kev count: %w", err)
	}
	return n, nil
}

func (r *Repo) RecentByDateAdded(
	ctx context.Context,
	limit int,
) ([]Row, error) {
	if limit <= 0 {
		limit = 50
	}
	var rows []Row
	err := r.db.SelectContext(ctx, &rows, `
		SELECT cve_id, vendor, product, vulnerability_name, date_added, due_date,
		       ransomware_use, payload
		  FROM kev_entries
		 ORDER BY date_added DESC, cve_id DESC
		 LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("recent kev: %w", err)
	}
	return rows, nil
}
