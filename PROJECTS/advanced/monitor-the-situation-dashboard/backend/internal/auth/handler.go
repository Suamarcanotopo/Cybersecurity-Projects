// AngelaMos | 2026
// handler.go

package auth

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-playground/validator/v10"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/middleware"
)

const (
	refreshCookieName   = "mts_rt"
	refreshCookiePath   = "/api/v1/auth"
	refreshCookieMaxAge = 7 * 24 * time.Hour
)

type Handler struct {
	service          *Service
	validator        *validator.Validate
	trustedProxyHops int
	secureCookies    bool
}

type HandlerConfig struct {
	Service          *Service
	TrustedProxyHops int
	SecureCookies    bool
}

func NewHandler(service *Service, trustedProxyHops int) *Handler {
	return NewHandlerWithConfig(HandlerConfig{
		Service:          service,
		TrustedProxyHops: trustedProxyHops,
	})
}

func NewHandlerWithConfig(cfg HandlerConfig) *Handler {
	return &Handler{
		service:          cfg.Service,
		validator:        validator.New(validator.WithRequiredStructEnabled()),
		trustedProxyHops: cfg.TrustedProxyHops,
		secureCookies:    cfg.SecureCookies,
	}
}

func (h *Handler) setRefreshCookie(
	w http.ResponseWriter,
	token string,
	expiresAt time.Time,
) {
	http.SetCookie(w, &http.Cookie{
		Name:     refreshCookieName,
		Value:    token,
		Path:     refreshCookiePath,
		HttpOnly: true,
		Secure:   h.secureCookies,
		SameSite: http.SameSiteStrictMode,
		Expires:  expiresAt,
	})
}

func (h *Handler) clearRefreshCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     refreshCookieName,
		Value:    "",
		Path:     refreshCookiePath,
		HttpOnly: true,
		Secure:   h.secureCookies,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
	})
}

func (h *Handler) refreshTokenFromRequest(r *http.Request, body string) string {
	if body != "" {
		return body
	}
	if c, err := r.Cookie(refreshCookieName); err == nil {
		return c.Value
	}
	return ""
}

func (h *Handler) RegisterRoutes(
	r chi.Router,
	authenticator func(http.Handler) http.Handler,
) {
	r.Route("/auth", func(r chi.Router) {
		r.Post("/login", h.Login)
		r.Post("/register", h.Register)
		r.Post("/refresh", h.Refresh)

		r.Group(func(r chi.Router) {
			r.Use(authenticator)
			r.Get("/me", h.GetMe)
			r.Post("/logout", h.Logout)
			r.Post("/logout-all", h.LogoutAll)
			r.Get("/sessions", h.GetSessions)
			r.Delete("/sessions/{sessionID}", h.RevokeSession)
			r.Post("/change-password", h.ChangePassword)
		})
	})
}

func (h *Handler) Login(w http.ResponseWriter, r *http.Request) {
	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		core.BadRequest(w, "invalid request body")
		return
	}

	if err := h.validator.Struct(req); err != nil {
		core.BadRequest(w, core.FormatValidationError(err))
		return
	}

	userAgent := r.UserAgent()
	ipAddress := h.extractIPAddress(r)

	resp, err := h.service.Login(r.Context(), req, userAgent, ipAddress)
	if err != nil {
		if errors.Is(err, ErrInvalidCredentials) {
			core.JSONError(
				w,
				core.UnauthorizedError("invalid email or password"),
			)
			return
		}
		core.InternalServerError(w, err)
		return
	}

	h.setRefreshCookie(
		w,
		resp.Tokens.RefreshToken,
		time.Now().Add(refreshCookieMaxAge),
	)
	core.OK(w, resp)
}

func (h *Handler) Register(w http.ResponseWriter, r *http.Request) {
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		core.BadRequest(w, "invalid request body")
		return
	}

	if err := h.validator.Struct(req); err != nil {
		core.BadRequest(w, core.FormatValidationError(err))
		return
	}

	userAgent := r.UserAgent()
	ipAddress := h.extractIPAddress(r)

	resp, err := h.service.Register(r.Context(), req, userAgent, ipAddress)
	if err != nil {
		if errors.Is(err, ErrEmailExists) {
			core.JSONError(w, core.DuplicateError("email"))
			return
		}
		core.InternalServerError(w, err)
		return
	}

	h.setRefreshCookie(
		w,
		resp.Tokens.RefreshToken,
		time.Now().Add(refreshCookieMaxAge),
	)
	core.Created(w, resp)
}

func (h *Handler) Refresh(w http.ResponseWriter, r *http.Request) {
	var req RefreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		// Body may be empty when frontend uses cookie-only flow.
		req = RefreshRequest{}
	}

	refreshToken := h.refreshTokenFromRequest(r, req.RefreshToken)
	if refreshToken == "" {
		core.BadRequest(w, "refresh_token required (cookie or body)")
		return
	}

	userAgent := r.UserAgent()
	ipAddress := h.extractIPAddress(r)

	resp, err := h.service.Refresh(
		r.Context(),
		refreshToken,
		userAgent,
		ipAddress,
	)
	if err != nil {
		if errors.Is(err, ErrTokenReuse) {
			core.JSONError(w, core.NewAppError(
				core.ErrTokenRevoked,
				"security alert: token reuse detected, all sessions revoked",
				http.StatusUnauthorized,
				"TOKEN_REUSE_DETECTED",
			))
			return
		}
		if errors.Is(err, core.ErrTokenExpired) {
			core.JSONError(w, core.TokenExpiredError())
			return
		}
		if errors.Is(err, core.ErrTokenRevoked) {
			core.JSONError(w, core.TokenRevokedError())
			return
		}
		if errors.Is(err, core.ErrTokenInvalid) {
			core.JSONError(w, core.TokenInvalidError())
			return
		}
		core.InternalServerError(w, err)
		return
	}

	h.setRefreshCookie(
		w,
		resp.Tokens.RefreshToken,
		time.Now().Add(refreshCookieMaxAge),
	)
	core.OK(w, resp)
}

func (h *Handler) Logout(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	if userID == "" {
		core.Unauthorized(w, "")
		return
	}

	var req RefreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		req = RefreshRequest{}
	}
	refreshToken := h.refreshTokenFromRequest(r, req.RefreshToken)

	var jti string
	var expiresAt time.Time
	if claims := middleware.GetClaims(r.Context()); claims != nil {
		jti = claims.JTI
		expiresAt = claims.ExpiresAt
	}

	if err := h.service.Logout(
		r.Context(),
		refreshToken,
		userID,
		jti,
		expiresAt,
	); err != nil {
		if errors.Is(err, core.ErrForbidden) {
			core.Forbidden(w, "cannot revoke another user's token")
			return
		}
		core.InternalServerError(w, err)
		return
	}

	h.clearRefreshCookie(w)
	core.NoContent(w)
}

func (h *Handler) LogoutAll(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	if userID == "" {
		core.Unauthorized(w, "")
		return
	}

	if err := h.service.LogoutAll(r.Context(), userID); err != nil {
		core.InternalServerError(w, err)
		return
	}

	core.NoContent(w)
}

func (h *Handler) GetSessions(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	if userID == "" {
		core.Unauthorized(w, "")
		return
	}

	sessions, err := h.service.GetActiveSessions(r.Context(), userID)
	if err != nil {
		core.InternalServerError(w, err)
		return
	}

	core.OK(w, SessionsResponse{Sessions: sessions})
}

func (h *Handler) RevokeSession(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	if userID == "" {
		core.Unauthorized(w, "")
		return
	}

	sessionID := chi.URLParam(r, "sessionID")
	if sessionID == "" {
		core.BadRequest(w, "session ID required")
		return
	}

	if err := h.service.RevokeSession(
		r.Context(),
		userID,
		sessionID,
	); err != nil {
		if errors.Is(err, core.ErrNotFound) {
			core.NotFound(w, "session")
			return
		}
		if errors.Is(err, core.ErrForbidden) {
			core.Forbidden(w, "cannot revoke another user's session")
			return
		}
		core.InternalServerError(w, err)
		return
	}

	core.NoContent(w)
}

func (h *Handler) ChangePassword(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	if userID == "" {
		core.Unauthorized(w, "")
		return
	}

	var req ChangePasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		core.BadRequest(w, "invalid request body")
		return
	}

	if err := h.validator.Struct(req); err != nil {
		core.BadRequest(w, core.FormatValidationError(err))
		return
	}

	if err := h.service.ChangePassword(
		r.Context(),
		userID,
		req.CurrentPassword,
		req.NewPassword,
	); err != nil {
		if errors.Is(err, ErrInvalidCredentials) {
			core.JSONError(
				w,
				core.UnauthorizedError("current password is incorrect"),
			)
			return
		}
		core.InternalServerError(w, err)
		return
	}

	core.NoContent(w)
}

func (h *Handler) GetMe(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	if userID == "" {
		core.Unauthorized(w, "")
		return
	}

	user, err := h.service.GetCurrentUser(r.Context(), userID)
	if err != nil {
		if errors.Is(err, core.ErrNotFound) {
			core.NotFound(w, "user")
			return
		}
		core.InternalServerError(w, err)
		return
	}

	core.OK(w, user)
}

func (h *Handler) extractIPAddress(r *http.Request) string {
	return middleware.ClientIP(r, h.trustedProxyHops)
}
