// ©AngelaMos | 2026
// handler.go

package notifications

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-playground/validator/v10"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/middleware"
)

const headerTelegramSecret = "X-Telegram-Bot-Api-Secret-Token"

type Handler struct {
	service   *Service
	validator *validator.Validate
}

func NewHandler(service *Service) *Handler {
	return &Handler{
		service:   service,
		validator: validator.New(validator.WithRequiredStructEnabled()),
	}
}

func (h *Handler) RegisterRoutes(
	r chi.Router,
	authenticator func(http.Handler) http.Handler,
) {
	r.Route("/notifications", func(r chi.Router) {
		r.Post(
			"/telegram/webhook/{uuid}",
			h.HandleTelegramUpdate,
		)

		r.Group(func(r chi.Router) {
			r.Use(authenticator)

			r.Get("/channels", h.ListChannels)
			r.Post("/channels", h.CreateChannel)
			r.Delete("/channels/{id}", h.DeleteChannel)
			r.Post("/channels/{id}/test", h.TestChannel)

			r.Post("/telegram", h.RegisterTelegram)
			r.Delete("/telegram", h.UnlinkTelegram)
			r.Post("/telegram/test", h.TestTelegram)
			r.Get("/telegram/status", h.GetTelegramStatus)
		})
	})
}

func (h *Handler) ListChannels(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())

	resp, err := h.service.ListChannels(r.Context(), userID)
	if err != nil {
		core.InternalServerError(w, err)
		return
	}

	core.OK(w, resp)
}

func (h *Handler) CreateChannel(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())

	var req CreateChannelRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		core.BadRequest(w, "invalid request body")
		return
	}

	if err := h.validator.Struct(req); err != nil {
		core.BadRequest(w, core.FormatValidationError(err))
		return
	}

	ch, err := h.service.CreateChannel(r.Context(), userID, req)
	if err != nil {
		core.InternalServerError(w, err)
		return
	}

	core.Created(w, ch)
}

func (h *Handler) DeleteChannel(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	id := chi.URLParam(r, "id")

	if err := h.service.DeleteChannel(r.Context(), id, userID); err != nil {
		if errors.Is(err, core.ErrNotFound) {
			core.NotFound(w, "channel")
			return
		}
		core.InternalServerError(w, err)
		return
	}

	core.NoContent(w)
}

func (h *Handler) TestChannel(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	id := chi.URLParam(r, "id")

	if err := h.service.TestChannel(r.Context(), id, userID); err != nil {
		if errors.Is(err, core.ErrNotFound) {
			core.NotFound(w, "channel")
			return
		}
		core.JSONError(w, core.NewAppError(
			err,
			"test notification failed: "+err.Error(),
			http.StatusBadGateway,
			"NOTIFICATION_FAILED",
		))
		return
	}

	core.NoContent(w)
}

func (h *Handler) RegisterTelegram(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())

	var req RegisterTelegramRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		core.BadRequest(w, "invalid request body")
		return
	}

	if err := h.validator.Struct(req); err != nil {
		core.BadRequest(w, core.FormatValidationError(err))
		return
	}

	resp, err := h.service.RegisterTelegram(r.Context(), userID, req)
	if err != nil {
		core.InternalServerError(w, err)
		return
	}

	core.Created(w, resp)
}

func (h *Handler) UnlinkTelegram(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())

	if err := h.service.UnlinkTelegram(r.Context(), userID); err != nil {
		if errors.Is(err, core.ErrNotFound) {
			core.NotFound(w, "telegram channel")
			return
		}
		core.InternalServerError(w, err)
		return
	}

	core.NoContent(w)
}

func (h *Handler) TestTelegram(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())

	if err := h.service.TestTelegram(r.Context(), userID); err != nil {
		if errors.Is(err, core.ErrNotFound) {
			core.NotFound(w, "telegram channel")
			return
		}
		core.JSONError(w, core.NewAppError(
			err,
			err.Error(),
			http.StatusBadGateway,
			"NOTIFICATION_FAILED",
		))
		return
	}

	core.NoContent(w)
}

func (h *Handler) GetTelegramStatus(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())

	status, err := h.service.GetTelegramStatus(r.Context(), userID)
	if err != nil {
		core.InternalServerError(w, err)
		return
	}

	core.OK(w, status)
}

func (h *Handler) HandleTelegramUpdate(
	w http.ResponseWriter,
	r *http.Request,
) {
	webhookUUID := chi.URLParam(r, "uuid")
	secretToken := r.Header.Get(headerTelegramSecret)

	var update telegramUpdate
	if err := json.NewDecoder(r.Body).Decode(&update); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	if err := h.service.HandleTelegramUpdate(
		r.Context(), webhookUUID, secretToken, update,
	); err != nil {
		if errors.Is(err, core.ErrNotFound) ||
			errors.Is(err, core.ErrForbidden) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
}
