// ©AngelaMos | 2026
// repo.go

package cfradar

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/lib/pq"
)

type OutageRow struct {
	ID         string          `db:"id"`
	StartedAt  time.Time       `db:"started_at"`
	EndedAt    *time.Time      `db:"ended_at"`
	Locations  pq.StringArray  `db:"locations"`
	ASNs       pq.Int32Array   `db:"asns"`
	Cause      string          `db:"cause"`
	OutageType string          `db:"outage_type"`
	Payload    json.RawMessage `db:"payload"`
}

type HijackRow struct {
	ID          int64           `db:"id"`
	DetectedAt  time.Time       `db:"detected_at"`
	StartedAt   time.Time       `db:"started_at"`
	DurationSec int32           `db:"duration_sec"`
	Confidence  int16           `db:"confidence"`
	HijackerASN int32           `db:"hijacker_asn"`
	VictimASNs  pq.Int32Array   `db:"victim_asns"`
	Prefixes    []string        `db:"-"`
	Payload     json.RawMessage `db:"payload"`
}

type Repo struct {
	db *sqlx.DB
}

func NewRepo(db *sqlx.DB) *Repo { return &Repo{db: db} }

func (r *Repo) UpsertOutage(ctx context.Context, o OutageRow) error {
	if o.Locations == nil {
		o.Locations = pq.StringArray{}
	}
	if o.ASNs == nil {
		o.ASNs = pq.Int32Array{}
	}
	_, err := r.db.ExecContext(
		ctx,
		`
		INSERT INTO outage_events (id, started_at, ended_at, locations, asns, cause, outage_type, payload)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (id) DO UPDATE SET
			ended_at    = EXCLUDED.ended_at,
			locations   = EXCLUDED.locations,
			asns        = EXCLUDED.asns,
			cause       = EXCLUDED.cause,
			outage_type = EXCLUDED.outage_type,
			payload     = EXCLUDED.payload`,
		o.ID,
		o.StartedAt,
		o.EndedAt,
		o.Locations,
		o.ASNs,
		o.Cause,
		o.OutageType,
		[]byte(o.Payload),
	)
	if err != nil {
		return fmt.Errorf("upsert outage %s: %w", o.ID, err)
	}
	return nil
}

func (r *Repo) UpsertHijack(ctx context.Context, h HijackRow) error {
	if h.VictimASNs == nil {
		h.VictimASNs = pq.Int32Array{}
	}
	if h.Prefixes == nil {
		h.Prefixes = []string{}
	}
	_, err := r.db.ExecContext(
		ctx,
		`
		INSERT INTO bgp_hijack_events
			(id, detected_at, started_at, duration_sec, confidence, hijacker_asn, victim_asns, prefixes, payload)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8::cidr[], $9)
		ON CONFLICT (id) DO UPDATE SET
			detected_at  = EXCLUDED.detected_at,
			duration_sec = EXCLUDED.duration_sec,
			confidence   = EXCLUDED.confidence,
			payload      = EXCLUDED.payload`,
		h.ID,
		h.DetectedAt,
		h.StartedAt,
		h.DurationSec,
		h.Confidence,
		h.HijackerASN,
		h.VictimASNs,
		pq.Array(h.Prefixes),
		[]byte(h.Payload),
	)
	if err != nil {
		return fmt.Errorf("upsert hijack %d: %w", h.ID, err)
	}
	return nil
}

func (r *Repo) KnownOutageIDs(
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
		`SELECT id FROM outage_events WHERE id = ANY($1::text[])`,
		pq.Array(ids),
	); err != nil {
		return nil, fmt.Errorf("known outage ids: %w", err)
	}
	out := make(map[string]bool, len(found))
	for _, id := range found {
		out[id] = true
	}
	return out, nil
}

func (r *Repo) KnownHijackIDs(
	ctx context.Context,
	ids []int64,
) (map[int64]bool, error) {
	if len(ids) == 0 {
		return map[int64]bool{}, nil
	}
	var found []int64
	if err := r.db.SelectContext(
		ctx,
		&found,
		`SELECT id FROM bgp_hijack_events WHERE id = ANY($1::bigint[])`,
		pq.Array(ids),
	); err != nil {
		return nil, fmt.Errorf("known hijack ids: %w", err)
	}
	out := make(map[int64]bool, len(found))
	for _, id := range found {
		out[id] = true
	}
	return out, nil
}

func (r *Repo) RecentOutages(
	ctx context.Context,
	limit int,
) ([]OutageRow, error) {
	if limit <= 0 {
		limit = 50
	}
	var rows []OutageRow
	err := r.db.SelectContext(ctx, &rows, `
		SELECT id, started_at, ended_at, locations, asns, cause, outage_type, payload
		  FROM outage_events
		 ORDER BY started_at DESC
		 LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("recent outages: %w", err)
	}
	return rows, nil
}

func (r *Repo) RecentHijacks(
	ctx context.Context,
	limit int,
) ([]HijackRow, error) {
	if limit <= 0 {
		limit = 50
	}
	var rows []HijackRow
	err := r.db.SelectContext(ctx, &rows, `
		SELECT id, detected_at, started_at, duration_sec, confidence, hijacker_asn,
		       victim_asns, payload
		  FROM bgp_hijack_events
		 ORDER BY detected_at DESC
		 LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("recent hijacks: %w", err)
	}
	return rows, nil
}
