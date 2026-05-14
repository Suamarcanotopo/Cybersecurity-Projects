// ©AngelaMos | 2026
// collector_test.go

package gdelt_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/gdelt"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type fakeFetcher struct {
	mu      sync.Mutex
	calls   int
	buckets map[string][]gdelt.ThemeBucket
	err     error
}

func (f *fakeFetcher) FetchTheme(
	_ context.Context,
	theme string,
) ([]gdelt.ThemeBucket, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	return f.buckets[theme], nil
}

type fakeRepo struct {
	mu      sync.Mutex
	inserts []gdelt.SpikeRow
	seen    map[string]struct{}
}

func (r *fakeRepo) Insert(_ context.Context, row gdelt.SpikeRow) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.seen == nil {
		r.seen = map[string]struct{}{}
	}
	if _, ok := r.seen[row.ID]; ok {
		return false, nil
	}
	r.seen[row.ID] = struct{}{}
	r.inserts = append(r.inserts, row)
	return true, nil
}

func (r *fakeRepo) Inserts() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.inserts)
}

type fakeEmitter struct {
	mu     sync.Mutex
	events []events.Event
}

func (e *fakeEmitter) Emit(ev events.Event) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.events = append(e.events, ev)
}

func (e *fakeEmitter) Count() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.events)
}

type recordingState struct {
	mu        sync.Mutex
	successes int
	failures  int
}

func (s *recordingState) RecordSuccess(_ context.Context, _ string, _ int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.successes++
}

func (s *recordingState) RecordError(_ context.Context, _, _ string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failures++
}

func TestCollector_NoBaselineNoSpike(t *testing.T) {
	now := time.Now().UTC()
	buckets := []gdelt.ThemeBucket{
		{Theme: "X", Time: now, Count: 5000},
	}
	ftch := &fakeFetcher{buckets: map[string][]gdelt.ThemeBucket{"X": buckets}}
	repo := &fakeRepo{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := gdelt.NewCollector(gdelt.CollectorConfig{
		Interval:    20 * time.Millisecond,
		Themes:      []string{"X"},
		BaselineCap: 8,
		Fetcher:     ftch,
		Repo:        repo,
		Emitter:     emt,
		State:       st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.Equal(
		t,
		0,
		repo.Inserts(),
		"first observation has no baseline → cannot detect spike",
	)
	require.Equal(t, 0, emt.Count())
	require.Positive(t, st.successes)
}

func TestCollector_StableBaselinePlusSpikeEmitsOnce(t *testing.T) {
	base := time.Now().UTC().Truncate(15 * time.Minute)
	stable := make([]gdelt.ThemeBucket, 0, 10)
	for i := 0; i < 10; i++ {
		stable = append(stable, gdelt.ThemeBucket{
			Theme: "X",
			Time:  base.Add(time.Duration(i) * 15 * time.Minute),
			Count: 100 + i,
		})
	}
	spikeBucket := gdelt.ThemeBucket{
		Theme: "X",
		Time:  base.Add(15 * 15 * time.Minute),
		Count: 5000,
	}
	buckets := append(stable, spikeBucket)

	ftch := &fakeFetcher{buckets: map[string][]gdelt.ThemeBucket{"X": buckets}}
	repo := &fakeRepo{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := gdelt.NewCollector(gdelt.CollectorConfig{
		Interval:    20 * time.Millisecond,
		Themes:      []string{"X"},
		BaselineCap: 8,
		Fetcher:     ftch,
		Repo:        repo,
		Emitter:     emt,
		State:       st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		80*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(t, repo.Inserts(), 1, "spike must be inserted")
	require.GreaterOrEqual(t, emt.Count(), 1)
	for _, ev := range emt.events {
		require.Equal(t, events.TopicGDELTSpike, ev.Topic)
	}
}

func TestCollector_FetchErrorsRecordsState(t *testing.T) {
	ftch := &fakeFetcher{err: errors.New("upstream 503")}
	repo := &fakeRepo{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := gdelt.NewCollector(gdelt.CollectorConfig{
		Interval:    20 * time.Millisecond,
		Themes:      []string{"X"},
		BaselineCap: 8,
		Fetcher:     ftch,
		Repo:        repo,
		Emitter:     emt,
		State:       st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		60*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.Equal(t, 0, repo.Inserts())
	require.Positive(t, st.failures)
}
