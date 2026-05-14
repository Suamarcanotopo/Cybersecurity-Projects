// ©AngelaMos | 2026
// collector_test.go

package dshield_test

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/dshield"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type fakeFetcher struct {
	mu    sync.Mutex
	calls int
	err   error
}

func (f *fakeFetcher) FetchAll(
	_ context.Context,
) ([]dshield.SnapshotPayload, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	return []dshield.SnapshotPayload{
		{Kind: dshield.KindTopPorts, Payload: json.RawMessage(`[{"port":22}]`)},
		{
			Kind:    dshield.KindTopIPs,
			Payload: json.RawMessage(`[{"ip":"1.2.3.4"}]`),
		},
		{
			Kind:    dshield.KindDailySummary,
			Payload: json.RawMessage(`[{"records":42}]`),
		},
	}, nil
}

func (f *fakeFetcher) Calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

type persistedRow struct {
	Kind string
	Body json.RawMessage
}

type fakePersister struct {
	mu   sync.Mutex
	rows []persistedRow
}

func (p *fakePersister) PutSnapshot(
	_ context.Context,
	_ time.Time,
	kind string,
	body json.RawMessage,
) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.rows = append(p.rows, persistedRow{Kind: kind, Body: body})
	return nil
}

func (p *fakePersister) Rows() []persistedRow {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]persistedRow, len(p.rows))
	copy(out, p.rows)
	return out
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

func (e *fakeEmitter) Events() []events.Event {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]events.Event, len(e.events))
	copy(out, e.events)
	return out
}

type recordingState struct {
	mu        sync.Mutex
	successes int
	successN  int64
	failures  int
	lastErr   string
}

func (s *recordingState) RecordSuccess(_ context.Context, _ string, n int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.successes++
	s.successN += n
}

func (s *recordingState) RecordError(_ context.Context, _, msg string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failures++
	s.lastErr = msg
}

func TestCollector_TickPersistsAllAndEmitsScanFirehose(t *testing.T) {
	ftch := &fakeFetcher{}
	prst := &fakePersister{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := dshield.NewCollector(dshield.CollectorConfig{
		Interval:  20 * time.Millisecond,
		Fetcher:   ftch,
		Persister: prst,
		Emitter:   emt,
		State:     st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		70*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(t, ftch.Calls(), 2)
	require.GreaterOrEqual(t, len(prst.Rows()), 6)

	evs := emt.Events()
	require.GreaterOrEqual(t, len(evs), 2)
	for _, ev := range evs {
		require.Equal(t, events.TopicScanFirehose, ev.Topic)
		require.Equal(t, dshield.Name, ev.Source)
		body, ok := ev.Payload.(json.RawMessage)
		require.True(t, ok, "payload must be json.RawMessage")

		var merged map[string]json.RawMessage
		require.NoError(t, json.Unmarshal(body, &merged))
		require.Contains(t, merged, dshield.KindTopPorts)
		require.Contains(t, merged, dshield.KindTopIPs)
		require.Contains(t, merged, dshield.KindDailySummary)
		require.Contains(t, merged, "ts")
	}

	require.Positive(t, st.successes)
	require.Equal(t, 0, st.failures)
}

func TestCollector_FetchErrorRecordsState(t *testing.T) {
	ftch := &fakeFetcher{err: errors.New("upstream 503")}
	prst := &fakePersister{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := dshield.NewCollector(dshield.CollectorConfig{
		Interval:  20 * time.Millisecond,
		Fetcher:   ftch,
		Persister: prst,
		Emitter:   emt,
		State:     st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.Empty(t, prst.Rows())
	require.Empty(t, emt.Events())
	require.Positive(t, st.failures)
	require.Contains(t, st.lastErr, "upstream 503")
}
