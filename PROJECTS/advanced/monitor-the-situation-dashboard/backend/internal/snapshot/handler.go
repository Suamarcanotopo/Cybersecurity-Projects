// ©AngelaMos | 2026
// handler.go

package snapshot

import (
	"net/http"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
)

type Handler struct {
	store *Store
}

func NewHandler(store *Store) *Handler { return &Handler{store: store} }

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	all, err := h.store.GetAll(r.Context())
	if err != nil {
		core.InternalServerError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	core.OK(w, all)
}
