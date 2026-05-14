// ©AngelaMos | 2026
// collector_test.go

package swpc_test

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/swpc"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type fakeFetcher struct {
	plasma []swpc.PlasmaTick
	mag    []swpc.MagTick
	kp     []swpc.KpTick
	xray   []swpc.XrayTick
	alerts []swpc.AlertItem
	err    error
}

func (f *fakeFetcher) FetchPlasma(
	_ context.Context,
) ([]swpc.PlasmaTick, error) {
	return f.plasma, f.err
}

func (f *fakeFetcher) FetchMag(
	_ context.Context,
) ([]swpc.MagTick, error) {
	return f.mag, f.err
}

func (f *fakeFetcher) FetchKp(
	_ context.Context,
) ([]swpc.KpTick, error) {
	return f.kp, f.err
}

func (f *fakeFetcher) FetchXray(_ context.Context) ([]swpc.XrayTick, error) {
	return f.xray, f.err
}

func (f *fakeFetcher) FetchAlerts(_ context.Context) ([]swpc.AlertItem, error) {
	return f.alerts, f.err
}

type fakeRing struct {
	mu     sync.Mutex
	pushes map[string]int
}

func (r *fakeRing) Push(
	_ context.Context,
	key string,
	_ int64,
	_ []byte,
) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.pushes == nil {
		r.pushes = make(map[string]int)
	}
	r.pushes[key]++
	return nil
}

func (r *fakeRing) PushCount(key string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.pushes[key]
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

func TestCollector_FastTickPushesToRingsAndEmits(t *testing.T) {
	now := time.Now().UTC()
	ftch := &fakeFetcher{
		plasma: []swpc.PlasmaTick{
			{TimeTag: now, Density: "2.94", Speed: "450", Temperature: "93030"},
		},
		mag: []swpc.MagTick{{TimeTag: now, Bt: "5.6"}},
		xray: []swpc.XrayTick{
			{TimeTag: now, Flux: 1e-7, Energy: "0.1-0.8nm"},
		},
		alerts: []swpc.AlertItem{
			{ProductID: "TIIA", IssueDatetime: now, Message: "test alert"},
		},
		kp: []swpc.KpTick{{TimeTag: now, Kp: 3.0}},
	}
	ring := &fakeRing{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := swpc.NewCollector(swpc.CollectorConfig{
		FastInterval: 20 * time.Millisecond,
		SlowInterval: 50 * time.Millisecond,
		Fetcher:      ftch,
		Ring:         ring,
		Emitter:      emt,
		State:        st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		80*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(t, ring.PushCount("swpc:plasma"), 1)
	require.GreaterOrEqual(t, ring.PushCount("swpc:mag"), 1)
	require.GreaterOrEqual(t, ring.PushCount("swpc:xray"), 1)
	require.GreaterOrEqual(t, ring.PushCount("swpc:alerts"), 1)
	require.GreaterOrEqual(t, ring.PushCount("swpc:kp"), 1)

	require.GreaterOrEqual(t, emt.Count(), 1)
	for _, ev := range emt.events {
		require.Equal(t, events.TopicSpaceWeather, ev.Topic)
	}
	require.Positive(t, st.successes)
	require.Equal(t, 0, st.failures)
}

func TestCollector_EmitsRichPayloadWithLatestReadings(t *testing.T) {
	now := time.Now().UTC()
	ftch := &fakeFetcher{
		plasma: []swpc.PlasmaTick{
			{TimeTag: now.Add(-2 * time.Minute), Density: "1.0", Speed: "300"},
			{TimeTag: now, Density: "5.42", Speed: "487"},
		},
		mag: []swpc.MagTick{
			{TimeTag: now.Add(-2 * time.Minute), BzGSM: "1.5"},
			{TimeTag: now, BzGSM: "-3.21"},
		},
		xray: []swpc.XrayTick{
			{TimeTag: now.Add(-2 * time.Minute), Flux: 1e-7},
			{TimeTag: now, Flux: 2.5e-5},
		},
		alerts: []swpc.AlertItem{},
		kp:     []swpc.KpTick{{TimeTag: now, Kp: 4.0}},
	}
	ring := &fakeRing{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := swpc.NewCollector(swpc.CollectorConfig{
		FastInterval: 20 * time.Millisecond,
		SlowInterval: 25 * time.Millisecond,
		Fetcher:      ftch,
		Ring:         ring,
		Emitter:      emt,
		State:        st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		60*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(t, emt.Count(), 1)

	emt.mu.Lock()
	last := emt.events[len(emt.events)-1]
	emt.mu.Unlock()

	raw, ok := last.Payload.(json.RawMessage)
	require.True(t, ok, "expected payload to be json.RawMessage")
	var payload map[string]any
	require.NoError(t, json.Unmarshal(raw, &payload))

	require.InDelta(t, 487.0, payload["speed_kms"], 0.001)
	require.InDelta(t, 5.42, payload["density"], 0.001)
	require.InDelta(t, -3.21, payload["bz_gsm"], 0.001)
	require.InDelta(t, 2.5e-5, payload["xray_flux"], 1e-9)
	require.Equal(t, "M2.5", payload["xray_class"])
	require.InDelta(t, 4.0, payload["kp"], 0.001)
}

func TestCollector_FetchErrorsRecordsState(t *testing.T) {
	ftch := &fakeFetcher{err: errors.New("upstream 503")}
	ring := &fakeRing{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := swpc.NewCollector(swpc.CollectorConfig{
		FastInterval: 20 * time.Millisecond,
		SlowInterval: 50 * time.Millisecond,
		Fetcher:      ftch,
		Ring:         ring,
		Emitter:      emt,
		State:        st,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		60*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.Equal(t, 0, ring.PushCount("swpc:plasma"))
	require.Positive(t, st.failures)
}
