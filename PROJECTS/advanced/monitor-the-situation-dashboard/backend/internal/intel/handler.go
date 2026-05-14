// ©AngelaMos | 2026
// handler.go

package intel

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cfradar"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cve"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/kev"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/ransomware"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/usgs"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
)

// Backfill endpoints. The dashboard's snapshot store keeps only the latest
// SINGLE event per topic, so on cold load the panels are nearly empty until
// the next collector tick fires (up to 2h for CVE). These endpoints read
// directly from the persistent stores so the panels populate immediately,
// and the WS path layers deltas on top.
//
// All routes are GET, public (same posture as /snapshot), with a small
// public cache to absorb the cold-load thundering herd if the dashboard
// happens to be popular.

const (
	defaultLimit = 50
	maxLimit     = 500
	cacheMaxAgeS = 30
	cacheControl = "public, max-age=30"
	contentType  = "Content-Type"
	contentJSON  = "application/json"
)

type CVERepo interface {
	RecentByLastModified(ctx context.Context, limit int) ([]cve.Row, error)
}

type KEVRepo interface {
	RecentByDateAdded(ctx context.Context, limit int) ([]kev.Row, error)
}

type CFRadarRepo interface {
	RecentHijacks(ctx context.Context, limit int) ([]cfradar.HijackRow, error)
	RecentOutages(ctx context.Context, limit int) ([]cfradar.OutageRow, error)
}

type RansomwareRepo interface {
	Recent(ctx context.Context, limit int) ([]ransomware.Row, error)
}

type USGSRepo interface {
	RecentByTime(ctx context.Context, limit int) ([]usgs.Row, error)
}

type Handler struct {
	cveRepo        CVERepo
	kevRepo        KEVRepo
	cfradarRepo    CFRadarRepo
	ransomwareRepo RansomwareRepo
	usgsRepo       USGSRepo
}

type HandlerConfig struct {
	CVE        CVERepo
	KEV        KEVRepo
	CFRadar    CFRadarRepo
	Ransomware RansomwareRepo
	USGS       USGSRepo
}

func NewHandler(cfg HandlerConfig) *Handler {
	return &Handler{
		cveRepo:        cfg.CVE,
		kevRepo:        cfg.KEV,
		cfradarRepo:    cfg.CFRadar,
		ransomwareRepo: cfg.Ransomware,
		usgsRepo:       cfg.USGS,
	}
}

func (h *Handler) RegisterRoutes(r chi.Router) {
	r.Route("/intel", func(r chi.Router) {
		r.Get("/cves", h.recentCVEs)
		r.Get("/kev", h.recentKEV)
		r.Get("/hijacks", h.recentHijacks)
		r.Get("/outages", h.recentOutages)
		r.Get("/ransomware", h.recentRansomware)
		r.Get("/quakes", h.recentQuakes)
	})
}

func parseLimit(r *http.Request) int {
	raw := r.URL.Query().Get("limit")
	if raw == "" {
		return defaultLimit
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return defaultLimit
	}
	if n > maxLimit {
		return maxLimit
	}
	return n
}

func (h *Handler) recentCVEs(w http.ResponseWriter, r *http.Request) {
	if h.cveRepo == nil {
		core.OK(w, []any{})
		return
	}
	rows, err := h.cveRepo.RecentByLastModified(r.Context(), parseLimit(r))
	if err != nil {
		core.InternalServerError(w, err)
		return
	}
	w.Header().Set("Cache-Control", cacheControl)
	core.OK(w, intelCVERows(rows))
}

func (h *Handler) recentKEV(w http.ResponseWriter, r *http.Request) {
	if h.kevRepo == nil {
		core.OK(w, []any{})
		return
	}
	rows, err := h.kevRepo.RecentByDateAdded(r.Context(), parseLimit(r))
	if err != nil {
		core.InternalServerError(w, err)
		return
	}
	w.Header().Set("Cache-Control", cacheControl)
	core.OK(w, intelKEVRows(rows))
}

// recentHijacks returns the raw payload column (the same EnrichedHijack
// JSON the WS path emits at collector time) so the dashboard panel sees
// `prefixes` and `enrichment` alongside the row metadata. Building a
// flat DTO loses fields the panel renders → empty rows.
func (h *Handler) recentHijacks(w http.ResponseWriter, r *http.Request) {
	if h.cfradarRepo == nil {
		core.OK(w, []any{})
		return
	}
	rows, err := h.cfradarRepo.RecentHijacks(r.Context(), parseLimit(r))
	if err != nil {
		core.InternalServerError(w, err)
		return
	}
	out := make([]json.RawMessage, 0, len(rows))
	for _, r := range rows {
		if len(r.Payload) > 0 {
			out = append(out, r.Payload)
		}
	}
	w.Header().Set("Cache-Control", cacheControl)
	core.OK(w, out)
}

// recentOutages returns the raw OutageAnnotation payload the WS path
// emits, for the same reason as recentHijacks.
func (h *Handler) recentOutages(w http.ResponseWriter, r *http.Request) {
	if h.cfradarRepo == nil {
		core.OK(w, []any{})
		return
	}
	rows, err := h.cfradarRepo.RecentOutages(r.Context(), parseLimit(r))
	if err != nil {
		core.InternalServerError(w, err)
		return
	}
	out := make([]json.RawMessage, 0, len(rows))
	for _, r := range rows {
		if len(r.Payload) > 0 {
			out = append(out, r.Payload)
		}
	}
	w.Header().Set("Cache-Control", cacheControl)
	core.OK(w, out)
}

// recentRansomware returns the raw Victim payload the WS path emits, so
// dedupe by victimKey() works identically across cold-load and live.
func (h *Handler) recentRansomware(w http.ResponseWriter, r *http.Request) {
	if h.ransomwareRepo == nil {
		core.OK(w, []any{})
		return
	}
	rows, err := h.ransomwareRepo.Recent(r.Context(), parseLimit(r))
	if err != nil {
		core.InternalServerError(w, err)
		return
	}
	out := make([]json.RawMessage, 0, len(rows))
	for _, r := range rows {
		if len(r.Payload) > 0 {
			out = append(out, r.Payload)
		}
	}
	w.Header().Set("Cache-Control", cacheControl)
	core.OK(w, out)
}

func (h *Handler) recentQuakes(w http.ResponseWriter, r *http.Request) {
	if h.usgsRepo == nil {
		core.OK(w, []any{})
		return
	}
	rows, err := h.usgsRepo.RecentByTime(r.Context(), parseLimit(r))
	if err != nil {
		core.InternalServerError(w, err)
		return
	}
	// Return the raw GeoJSON Feature shape the frontend (and the live WS
	// path) already speak. Row.Payload IS the upstream feature.
	out := make([]json.RawMessage, 0, len(rows))
	for _, r := range rows {
		if len(r.Payload) > 0 {
			out = append(out, r.Payload)
		}
	}
	w.Header().Set("Cache-Control", cacheControl)
	core.OK(w, out)
}

// The collectors' Row types embed the raw upstream payload as
// json.RawMessage. The dashboard panels consume the upstream shape (CveID,
// Severity, etc.), so we forward the payloads — they're already the right
// shape for the existing zod schemas on the frontend. For panels that
// derive fields server-side (severity/cvss numeric vs the NVD nested
// structure) we expand back to the same flat shape the live WS event
// emits, so the frontend stores can dedupe by ID across cold-load and live
// streams without remembering two formats.

type cveDTO struct {
	CveID          string          `json:"CveID"`
	Published      time.Time       `json:"Published"`
	LastModified   time.Time       `json:"LastModified"`
	Severity       string          `json:"Severity"`
	CVSS           float64         `json:"CVSS"`
	EPSSScore      *float64        `json:"EPSSScore"`
	EPSSPercentile *float64        `json:"EPSSPercentile"`
	InKEV          bool            `json:"InKEV"`
	Payload        json.RawMessage `json:"-"`
}

func intelCVERows(rows []cve.Row) []cveDTO {
	out := make([]cveDTO, 0, len(rows))
	for _, r := range rows {
		out = append(out, cveDTO{
			CveID:          r.CveID,
			Published:      r.Published,
			LastModified:   r.LastModified,
			Severity:       r.Severity,
			CVSS:           r.CVSS,
			EPSSScore:      r.EPSSScore,
			EPSSPercentile: r.EPSSPercentile,
			InKEV:          r.InKEV,
		})
	}
	return out
}

type kevDTO struct {
	CveID                      string `json:"cveID"`
	VendorProject              string `json:"vendorProject"`
	Product                    string `json:"product"`
	VulnerabilityName          string `json:"vulnerabilityName"`
	DateAdded                  string `json:"dateAdded"`
	DueDate                    string `json:"dueDate,omitempty"`
	KnownRansomwareCampaignUse string `json:"knownRansomwareCampaignUse,omitempty"`
}

func intelKEVRows(rows []kev.Row) []kevDTO {
	out := make([]kevDTO, 0, len(rows))
	for _, r := range rows {
		dto := kevDTO{
			CveID:                      r.CveID,
			VendorProject:              r.Vendor,
			Product:                    r.Product,
			VulnerabilityName:          r.VulnerabilityName,
			DateAdded:                  r.DateAdded.Format(time.DateOnly),
			KnownRansomwareCampaignUse: r.RansomwareUse,
		}
		if r.DueDate != nil {
			dto.DueDate = r.DueDate.Format(time.DateOnly)
		}
		out = append(out, dto)
	}
	return out
}

// Hijack/outage/ransomware endpoints all return the raw collector
// payload (the JSON the WS path emits), so the dashboard's panel-render
// fields like prefixes/enrichment survive the cold-load → live-stream
// transition without shape divergence.
