// ©AngelaMos | 2026
// collector_test.go

package iss_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/iss"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type fakeFetcher struct {
	mu     sync.Mutex
	pos    iss.Position
	tle    iss.TLE
	posErr error
	tleErr error
	posN   int
	tleN   int
}

func (f *fakeFetcher) FetchPosition(_ context.Context) (iss.Position, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.posN++
	return f.pos, f.posErr
}

func (f *fakeFetcher) FetchTLE(_ context.Context) (iss.TLE, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.tleN++
	return f.tle, f.tleErr
}

type fakeStore struct {
	mu    sync.Mutex
	saves int
	saved iss.TLE
}

func (s *fakeStore) Save(_ context.Context, tle iss.TLE) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.saves++
	s.saved = tle
	return nil
}

func (s *fakeStore) Load(_ context.Context) (iss.TLE, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.saves == 0 {
		return iss.TLE{}, false, nil
	}
	return s.saved, true, nil
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

func TestCollector_PositionLoopEmitsAndRecords(t *testing.T) {
	ftch := &fakeFetcher{
		pos: iss.Position{
			Latitude:  10,
			Longitude: 20,
			Altitude:  420,
			Velocity:  27500,
			Timestamp: 1234,
			FetchedAt: time.Now().UTC(),
		},
		tle: iss.TLE{Line1: "1 25544U ...", Line2: "2 25544 ..."},
	}
	store := &fakeStore{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := iss.NewCollector(iss.CollectorConfig{
		PositionInterval: 20 * time.Millisecond,
		TLEInterval:      time.Hour,
		Fetcher:          ftch,
		TLEStore:         store,
		Emitter:          emt,
		State:            st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		70*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(
		t,
		ftch.posN,
		2,
		"position should fire multiple times",
	)
	require.GreaterOrEqual(t, emt.Count(), 2)
	for _, ev := range emt.events {
		require.Equal(t, events.TopicISSPosition, ev.Topic)
	}
	require.Positive(t, st.successes)
}

func TestCollector_TLELoopSavesToStore(t *testing.T) {
	ftch := &fakeFetcher{
		pos: iss.Position{
			Latitude:  10,
			Longitude: 20,
			Altitude:  420,
			FetchedAt: time.Now().UTC(),
		},
		tle: iss.TLE{Line1: "1 25544U test", Line2: "2 25544 test"},
	}
	store := &fakeStore{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := iss.NewCollector(iss.CollectorConfig{
		PositionInterval: 50 * time.Millisecond,
		TLEInterval:      30 * time.Millisecond,
		Fetcher:          ftch,
		TLEStore:         store,
		Emitter:          emt,
		State:            st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		100*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(
		t,
		store.saves,
		2,
		"TLE should refresh multiple times in 100ms with 30ms interval",
	)
	require.Equal(t, "1 25544U test", store.saved.Line1)
}

func TestCollector_PositionFetchErrorRecordsState(t *testing.T) {
	ftch := &fakeFetcher{
		posErr: errors.New("upstream 503"),
		tle:    iss.TLE{Line1: "1 ...", Line2: "2 ..."},
	}
	store := &fakeStore{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := iss.NewCollector(iss.CollectorConfig{
		PositionInterval: 20 * time.Millisecond,
		TLEInterval:      time.Hour,
		Fetcher:          ftch,
		TLEStore:         store,
		Emitter:          emt,
		State:            st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.Equal(t, 0, emt.Count())
	require.Positive(t, st.failures)
}
