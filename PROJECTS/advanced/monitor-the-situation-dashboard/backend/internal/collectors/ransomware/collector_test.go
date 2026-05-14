// ©AngelaMos | 2026
// collector_test.go

package ransomware_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/ransomware"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type stubFetcher struct {
	victims []ransomware.Victim
}

func (s *stubFetcher) FetchRecent(
	context.Context,
) ([]ransomware.Victim, error) {
	return s.victims, nil
}

type stubRansomRepo struct {
	mu       sync.Mutex
	inserted []string
	known    map[string]bool
}

func (r *stubRansomRepo) Insert(_ context.Context, row ransomware.Row) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.inserted = append(r.inserted, row.ID)
	if r.known == nil {
		r.known = map[string]bool{}
	}
	r.known[row.ID] = true
	return nil
}

func (r *stubRansomRepo) KnownIDs(
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

func (r *stubRansomRepo) Inserted() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, len(r.inserted))
	copy(out, r.inserted)
	return out
}

type stubRansomEmitter struct {
	mu     sync.Mutex
	events []events.Event
}

func (e *stubRansomEmitter) Emit(ev events.Event) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.events = append(e.events, ev)
}

func (e *stubRansomEmitter) Events() []events.Event {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]events.Event, len(e.events))
	copy(out, e.events)
	return out
}

type stubRansomState struct{}

func (stubRansomState) RecordSuccess(context.Context, string, int64) {}
func (stubRansomState) RecordError(context.Context, string, string)  {}

func TestCollector_OnlyEmitsNewVictims(t *testing.T) {
	now := time.Now().UTC()
	known := ransomware.Victim{
		PostTitle:  "Old",
		GroupName:  "lockbit",
		Discovered: now.Add(-time.Hour),
	}
	new1 := ransomware.Victim{
		PostTitle:  "Acme",
		GroupName:  "blackcat",
		Discovered: now,
	}
	new2 := ransomware.Victim{
		PostTitle:  "Banco",
		GroupName:  "play",
		Discovered: now,
	}

	ftch := &stubFetcher{victims: []ransomware.Victim{known, new1, new2}}
	repo := &stubRansomRepo{known: map[string]bool{known.ID(): true}}
	emt := &stubRansomEmitter{}

	c := ransomware.NewCollector(ransomware.CollectorConfig{
		Interval: 30 * time.Millisecond,
		Fetcher:  ftch,
		Repo:     repo,
		Emitter:  emt,
		State:    stubRansomState{},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	inserted := repo.Inserted()
	require.Len(t, inserted, 2)

	evs := emt.Events()
	require.Len(t, evs, 2)
	for _, ev := range evs {
		require.Equal(t, events.TopicRansomwareVictim, ev.Topic)
		require.Equal(t, ransomware.Name, ev.Source)
	}
}
