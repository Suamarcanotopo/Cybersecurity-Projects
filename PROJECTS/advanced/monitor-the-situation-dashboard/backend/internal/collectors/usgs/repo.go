// ©AngelaMos | 2026
// repo.go

package usgs

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/lib/pq"
)

type Row struct {
	ID         string          `db:"id"`
	OccurredAt time.Time       `db:"occurred_at"`
	Mag        float64         `db:"mag"`
	Place      string          `db:"place"`
	GeomLon    float64         `db:"geom_lon"`
	GeomLat    float64         `db:"geom_lat"`
	DepthKm    float64         `db:"depth_km"`
	Payload    json.RawMessage `db:"payload"`
}

type Repo struct {
	db *sqlx.DB
}

func NewRepo(db *sqlx.DB) *Repo { return &Repo{db: db} }

func (r *Repo) Upsert(ctx context.Context, row Row) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO earthquakes (id, occurred_at, mag, place, geom_lon, geom_lat, depth_km, payload)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (id) DO UPDATE SET
			occurred_at = EXCLUDED.occurred_at,
			mag         = EXCLUDED.mag,
			place       = EXCLUDED.place,
			geom_lon    = EXCLUDED.geom_lon,
			geom_lat    = EXCLUDED.geom_lat,
			depth_km    = EXCLUDED.depth_km,
			payload     = EXCLUDED.payload`,
		row.ID, row.OccurredAt, row.Mag, row.Place,
		row.GeomLon, row.GeomLat, row.DepthKm, []byte(row.Payload),
	)
	if err != nil {
		return fmt.Errorf("upsert earthquake %s: %w", row.ID, err)
	}
	return nil
}

func (r *Repo) KnownIDs(
	ctx context.Context,
	ids []string,
) (map[string]bool, error) {
	out := make(map[string]bool, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	var found []string
	err := r.db.SelectContext(ctx, &found,
		`SELECT id FROM earthquakes WHERE id = ANY($1)`,
		pq.Array(ids),
	)
	if err != nil {
		return nil, fmt.Errorf("known earthquake ids: %w", err)
	}
	for _, id := range found {
		out[id] = true
	}
	return out, nil
}

func (r *Repo) RecentByMag(ctx context.Context, limit int) ([]Row, error) {
	var rows []Row
	err := r.db.SelectContext(ctx, &rows, `
		SELECT id, occurred_at, mag, place, geom_lon, geom_lat, depth_km, payload
		  FROM earthquakes
		 ORDER BY mag DESC, occurred_at DESC
		 LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("recent earthquakes: %w", err)
	}
	return rows, nil
}

func (r *Repo) RecentByTime(ctx context.Context, limit int) ([]Row, error) {
	if limit <= 0 {
		limit = 50
	}
	var rows []Row
	err := r.db.SelectContext(ctx, &rows, `
		SELECT id, occurred_at, mag, place, geom_lon, geom_lat, depth_km, payload
		  FROM earthquakes
		 ORDER BY occurred_at DESC
		 LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("recent earthquakes by time: %w", err)
	}
	return rows, nil
}
