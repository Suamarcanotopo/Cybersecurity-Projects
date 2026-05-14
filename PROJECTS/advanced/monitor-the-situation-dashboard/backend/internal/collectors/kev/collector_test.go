// ©AngelaMos | 2026
// collector_test.go

package kev_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/kev"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type stubFetcher struct {
	cat kev.Catalog
	err error
}

func (s *stubFetcher) FetchCatalog(context.Context) (kev.Catalog, error) {
	return s.cat, s.err
}

type stubKEVRepo struct {
	mu       sync.Mutex
	inserted []string
	known    map[string]bool
}

func (r *stubKEVRepo) Insert(_ context.Context, row kev.Row) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.inserted = append(r.inserted, row.CveID)
	if r.known == nil {
		r.known = map[string]bool{}
	}
	r.known[row.CveID] = true
	return nil
}

func (r *stubKEVRepo) KnownIDs(
	_ context.Context,
	ids []string,
) (map[string]bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make(map[string]bool)
	for _, id := range ids {
		if r.known[id] {
			out[id] = true
		}
	}
	return out, nil
}

func (r *stubKEVRepo) Inserted() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, len(r.inserted))
	copy(out, r.inserted)
	return out
}

type stubKEVEmitter struct {
	mu     sync.Mutex
	events []events.Event
}

func (e *stubKEVEmitter) Emit(ev events.Event) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.events = append(e.events, ev)
}

func (e *stubKEVEmitter) Events() []events.Event {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]events.Event, len(e.events))
	copy(out, e.events)
	return out
}

type stubKEVState struct{}

func (stubKEVState) RecordSuccess(context.Context, string, int64) {}
func (stubKEVState) RecordError(context.Context, string, string)  {}

func TestCollector_OnlyEmitsNewKEVs(t *testing.T) {
	ftch := &stubFetcher{cat: kev.Catalog{Vulnerabilities: []kev.Vulnerability{
		{CveID: "CVE-2024-OLD", VendorProject: "X", DateAdded: "2026-04-01"},
		{CveID: "CVE-2024-NEW", VendorProject: "Y", DateAdded: "2026-05-01"},
	}}}
	repo := &stubKEVRepo{known: map[string]bool{"CVE-2024-OLD": true}}
	emt := &stubKEVEmitter{}

	c := kev.NewCollector(kev.CollectorConfig{
		Interval: 30 * time.Millisecond,
		Fetcher:  ftch,
		Repo:     repo,
		Emitter:  emt,
		State:    stubKEVState{},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	inserted := repo.Inserted()
	require.NotEmpty(t, inserted)
	for _, id := range inserted {
		require.NotEqual(t, "CVE-2024-OLD", id)
		require.Equal(t, "CVE-2024-NEW", id)
	}

	evs := emt.Events()
	require.NotEmpty(t, evs)
	for _, ev := range evs {
		require.Equal(t, events.TopicKEVAdded, ev.Topic)
		require.Equal(t, kev.Name, ev.Source)
	}
}

func TestCollector_EmptyKnownInsertsAll(t *testing.T) {
	ftch := &stubFetcher{cat: kev.Catalog{Vulnerabilities: []kev.Vulnerability{
		{CveID: "CVE-A", DateAdded: "2026-04-01"},
		{CveID: "CVE-B", DateAdded: "2026-04-02"},
		{CveID: "CVE-C", DateAdded: "2026-04-03"},
	}}}
	repo := &stubKEVRepo{known: map[string]bool{}}
	emt := &stubKEVEmitter{}

	c := kev.NewCollector(kev.CollectorConfig{
		Interval: 25 * time.Millisecond,
		Fetcher:  ftch,
		Repo:     repo,
		Emitter:  emt,
		State:    stubKEVState{},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		30*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.Len(t, repo.Inserted(), 3)
	require.Len(t, emt.Events(), 3)
}
