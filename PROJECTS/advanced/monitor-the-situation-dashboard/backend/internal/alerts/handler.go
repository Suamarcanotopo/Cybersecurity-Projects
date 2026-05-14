// ©AngelaMos | 2026
// handler.go

package alerts

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"
	"github.com/go-playground/validator/v10"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/middleware"
)

type Handler struct {
	repo      Repository
	validator *validator.Validate
}

func NewHandler(repo Repository) *Handler {
	return &Handler{
		repo:      repo,
		validator: validator.New(validator.WithRequiredStructEnabled()),
	}
}

func (h *Handler) RegisterRoutes(
	r chi.Router,
	authenticator func(http.Handler) http.Handler,
) {
	r.Route("/me/alerts", func(r chi.Router) {
		r.Use(authenticator)

		r.Get("/", h.list)
		r.Post("/", h.create)
		r.Patch("/{id}", h.update)
		r.Delete("/{id}", h.delete)

		r.Get("/history", h.history)
	})
}

type ruleDTO struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Topic       string `json:"topic"`
	Predicate   string `json:"predicate"`
	CooldownSec int    `json:"cooldown_sec"`
	Enabled     bool   `json:"enabled"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
}

func toRuleDTO(r Rule) ruleDTO {
	return ruleDTO{
		ID:          r.ID,
		Name:        r.Name,
		Topic:       r.Topic,
		Predicate:   r.Predicate,
		CooldownSec: r.CooldownSec,
		Enabled:     r.Enabled,
		CreatedAt:   r.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"),
		UpdatedAt:   r.UpdatedAt.UTC().Format("2006-01-02T15:04:05Z"),
	}
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	rules, err := h.repo.ListByUser(r.Context(), userID)
	if err != nil {
		core.InternalServerError(w, err)
		return
	}
	out := make([]ruleDTO, 0, len(rules))
	for _, ru := range rules {
		out = append(out, toRuleDTO(ru))
	}
	core.OK(w, out)
}

type createRuleRequest struct {
	Name        string `json:"name"         validate:"required,min=1,max=200"`
	Topic       string `json:"topic"        validate:"required,min=1,max=64"`
	Predicate   string `json:"predicate"    validate:"omitempty,max=2048"`
	CooldownSec int    `json:"cooldown_sec" validate:"gte=0,lte=86400"`
	Enabled     bool   `json:"enabled"`
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req createRuleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		core.BadRequest(w, "invalid request body")
		return
	}
	if err := h.validator.Struct(req); err != nil {
		core.BadRequest(w, core.FormatValidationError(err))
		return
	}
	rule := &Rule{
		UserID:      userID,
		Name:        req.Name,
		Topic:       req.Topic,
		Predicate:   req.Predicate,
		CooldownSec: req.CooldownSec,
		Enabled:     req.Enabled,
	}
	if err := h.repo.Create(r.Context(), rule); err != nil {
		core.InternalServerError(w, err)
		return
	}
	core.Created(w, toRuleDTO(*rule))
}

type updateRuleRequest struct {
	Name        *string `json:"name,omitempty"         validate:"omitempty,min=1,max=200"`
	Predicate   *string `json:"predicate,omitempty"    validate:"omitempty,max=2048"`
	CooldownSec *int    `json:"cooldown_sec,omitempty" validate:"omitempty,gte=0,lte=86400"`
	Enabled     *bool   `json:"enabled,omitempty"`
}

func (h *Handler) update(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	id := chi.URLParam(r, "id")

	var req updateRuleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		core.BadRequest(w, "invalid request body")
		return
	}
	if err := h.validator.Struct(req); err != nil {
		core.BadRequest(w, core.FormatValidationError(err))
		return
	}

	rule, err := h.repo.Get(r.Context(), id, userID)
	if err != nil {
		if errors.Is(err, core.ErrNotFound) {
			core.NotFound(w, "rule")
			return
		}
		core.InternalServerError(w, err)
		return
	}
	if req.Name != nil {
		rule.Name = *req.Name
	}
	if req.Predicate != nil {
		rule.Predicate = *req.Predicate
	}
	if req.CooldownSec != nil {
		rule.CooldownSec = *req.CooldownSec
	}
	if req.Enabled != nil {
		rule.Enabled = *req.Enabled
	}
	if err := h.repo.Update(r.Context(), rule); err != nil {
		core.InternalServerError(w, err)
		return
	}
	core.OK(w, toRuleDTO(*rule))
}

func (h *Handler) delete(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	id := chi.URLParam(r, "id")
	if err := h.repo.Delete(r.Context(), id, userID); err != nil {
		if errors.Is(err, core.ErrNotFound) {
			core.NotFound(w, "rule")
			return
		}
		core.InternalServerError(w, err)
		return
	}
	core.NoContent(w)
}

func (h *Handler) history(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}
	rows, err := h.repo.RecentHistory(r.Context(), userID, limit)
	if err != nil {
		core.InternalServerError(w, err)
		return
	}
	core.OK(w, rows)
}
