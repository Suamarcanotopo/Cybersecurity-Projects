// ©AngelaMos | 2026
// repo.go

package cve

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
)

type Row struct {
	CveID          string          `db:"cve_id"`
	Published      time.Time       `db:"published"`
	LastModified   time.Time       `db:"last_modified"`
	Severity       string          `db:"severity"`
	CVSS           float64         `db:"cvss_score"`
	EPSSScore      *float64        `db:"epss_score"`
	EPSSPercentile *float64        `db:"epss_percentile"`
	InKEV          bool            `db:"in_kev"`
	Payload        json.RawMessage `db:"payload"`
}

type Repo struct {
	db *sqlx.DB
}

func NewRepo(db *sqlx.DB) *Repo { return &Repo{db: db} }

func (r *Repo) Upsert(ctx context.Context, row Row) error {
	_, err := r.db.ExecContext(
		ctx,
		`
		INSERT INTO cve_events (cve_id, published, last_modified, severity, cvss_score, payload)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (cve_id) DO UPDATE SET
			last_modified = EXCLUDED.last_modified,
			severity      = EXCLUDED.severity,
			cvss_score    = EXCLUDED.cvss_score,
			payload       = EXCLUDED.payload`,
		row.CveID,
		row.Published,
		row.LastModified,
		row.Severity,
		row.CVSS,
		[]byte(row.Payload),
	)
	if err != nil {
		return fmt.Errorf("upsert cve %s: %w", row.CveID, err)
	}
	return nil
}

func (r *Repo) UpdateEPSS(
	ctx context.Context,
	cveID string,
	score, percentile float64,
) error {
	_, err := r.db.ExecContext(
		ctx,
		`UPDATE cve_events SET epss_score = $2, epss_percentile = $3 WHERE cve_id = $1`,
		cveID,
		score,
		percentile,
	)
	if err != nil {
		return fmt.Errorf("update epss %s: %w", cveID, err)
	}
	return nil
}

func (r *Repo) Get(ctx context.Context, cveID string) (Row, error) {
	var row Row
	err := r.db.GetContext(ctx, &row, `
		SELECT cve_id, published, last_modified, severity, cvss_score,
		       epss_score, epss_percentile, in_kev, payload
		  FROM cve_events WHERE cve_id = $1`, cveID)
	if err != nil {
		return Row{}, fmt.Errorf("get cve %s: %w", cveID, err)
	}
	return row, nil
}

func (r *Repo) RecentByLastModified(
	ctx context.Context,
	limit int,
) ([]Row, error) {
	var rows []Row
	err := r.db.SelectContext(ctx, &rows, `
		SELECT cve_id, published, last_modified, severity, cvss_score,
		       epss_score, epss_percentile, in_kev, payload
		  FROM cve_events
		 ORDER BY last_modified DESC LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("recent cves: %w", err)
	}
	return rows, nil
}
