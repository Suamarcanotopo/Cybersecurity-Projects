// ©AngelaMos | 2026
// collector_test.go

package usgs_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/usgs"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type fakeFetcher struct {
	feed usgs.Feed
	err  error
	mu   sync.Mutex
	n    int
}

func (f *fakeFetcher) Fetch(_ context.Context) (usgs.Feed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.n++
	if f.err != nil {
		return usgs.Feed{}, f.err
	}
	return f.feed, nil
}

type fakeRepo struct {
	mu      sync.Mutex
	known   map[string]bool
	upserts []usgs.Row
}

func (r *fakeRepo) Upsert(_ context.Context, row usgs.Row) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.upserts = append(r.upserts, row)
	if r.known == nil {
		r.known = make(map[string]bool)
	}
	r.known[row.ID] = true
	return nil
}

func (r *fakeRepo) KnownIDs(
	_ context.Context,
	ids []string,
) (map[string]bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make(map[string]bool, len(ids))
	for _, id := range ids {
		if r.known[id] {
			out[id] = true
		}
	}
	return out, nil
}

func (r *fakeRepo) Upserts() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.upserts)
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
	lastErr   string
}

func (s *recordingState) RecordSuccess(_ context.Context, _ string, _ int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.successes++
}

func (s *recordingState) RecordError(_ context.Context, _, msg string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failures++
	s.lastErr = msg
}

func TestCollector_TickPersistsAndEmitsNewQuakes(t *testing.T) {
	feed := usgs.Feed{
		Type: "FeatureCollection",
		Features: []usgs.Feature{
			{
				ID: "q1",
				Properties: usgs.Properties{
					Mag:   4.5,
					Place: "test 1",
					Time:  time.Now().UnixMilli(),
				},
				Geometry: usgs.Geometry{Coordinates: []float64{-120, 49, 5}},
			},
			{
				ID: "q2",
				Properties: usgs.Properties{
					Mag:   6.5,
					Place: "test 2",
					Time:  time.Now().UnixMilli(),
				},
				Geometry: usgs.Geometry{Coordinates: []float64{140, -30, 10}},
			},
			{
				ID: "q3",
				Properties: usgs.Properties{
					Mag:   3.0,
					Place: "test 3",
					Time:  time.Now().UnixMilli(),
				},
				Geometry: usgs.Geometry{Coordinates: []float64{0, 0, 1}},
			},
		},
	}
	ftch := &fakeFetcher{feed: feed}
	repo := &fakeRepo{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := usgs.NewCollector(usgs.CollectorConfig{
		Interval: 20 * time.Millisecond,
		Fetcher:  ftch,
		Repo:     repo,
		Emitter:  emt,
		State:    st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		70*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(
		t,
		repo.Upserts(),
		3,
		"should upsert all 3 features at least once",
	)
	require.GreaterOrEqual(t, emt.Count(), 3, "should emit 3 new-event events")
	for _, ev := range emt.events {
		require.Equal(t, events.TopicEarthquake, ev.Topic)
		require.Equal(t, usgs.Name, ev.Source)
	}
	require.Positive(t, st.successes)
	require.Equal(t, 0, st.failures)
}

func TestCollector_FetchErrorRecordsState(t *testing.T) {
	ftch := &fakeFetcher{err: errors.New("upstream 503")}
	repo := &fakeRepo{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := usgs.NewCollector(usgs.CollectorConfig{
		Interval: 20 * time.Millisecond,
		Fetcher:  ftch,
		Repo:     repo,
		Emitter:  emt,
		State:    st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.Equal(t, 0, repo.Upserts())
	require.Equal(t, 0, emt.Count())
	require.Positive(t, st.failures)
	require.Contains(t, st.lastErr, "upstream 503")
}

func TestCollector_KnownQuakesNotReEmitted(t *testing.T) {
	feed := usgs.Feed{
		Features: []usgs.Feature{
			{
				ID: "qx",
				Properties: usgs.Properties{
					Mag:  4.5,
					Time: time.Now().UnixMilli(),
				},
				Geometry: usgs.Geometry{Coordinates: []float64{0, 0, 1}},
			},
		},
	}
	ftch := &fakeFetcher{feed: feed}
	repo := &fakeRepo{known: map[string]bool{"qx": true}}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := usgs.NewCollector(usgs.CollectorConfig{
		Interval: 20 * time.Millisecond,
		Fetcher:  ftch,
		Repo:     repo,
		Emitter:  emt,
		State:    st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.Equal(t, 0, emt.Count(), "known quake should not re-emit")
}
