// ©AngelaMos | 2026
// collector_test.go

package cfradar_test

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cfradar"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type fakeFetcher struct {
	outages cfradar.OutageResultBody
	hijacks cfradar.HijackBody
}

func (f *fakeFetcher) FetchOutages(
	context.Context,
) (cfradar.OutageResultBody, error) {
	return f.outages, nil
}

func (f *fakeFetcher) FetchHijacks(
	context.Context,
	int,
) (cfradar.HijackBody, error) {
	return f.hijacks, nil
}

type fakeRepo struct {
	mu            sync.Mutex
	outageUpserts int
	hijackUpserts int
	knownOutages  map[string]bool
	knownHijacks  map[int64]bool
}

func (r *fakeRepo) UpsertOutage(_ context.Context, _ cfradar.OutageRow) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.outageUpserts++
	return nil
}

func (r *fakeRepo) UpsertHijack(_ context.Context, _ cfradar.HijackRow) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.hijackUpserts++
	return nil
}

func (r *fakeRepo) KnownOutageIDs(
	_ context.Context,
	ids []string,
) (map[string]bool, error) {
	out := make(map[string]bool)
	for _, id := range ids {
		if r.knownOutages[id] {
			out[id] = true
		}
	}
	return out, nil
}

func (r *fakeRepo) KnownHijackIDs(
	_ context.Context,
	ids []int64,
) (map[int64]bool, error) {
	out := make(map[int64]bool)
	for _, id := range ids {
		if r.knownHijacks[id] {
			out[id] = true
		}
	}
	return out, nil
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

type noopState struct{}

func (noopState) RecordSuccess(context.Context, string, int64) {}
func (noopState) RecordError(context.Context, string, string)  {}

type fakeEnricher struct {
	calls    int
	verdict  cfradar.Enrichment
	lastIP   string
	returnFn func(ip string) (cfradar.Enrichment, error)
}

func (e *fakeEnricher) Lookup(
	_ context.Context,
	ip string,
) (cfradar.Enrichment, error) {
	e.calls++
	e.lastIP = ip
	if e.returnFn != nil {
		return e.returnFn(ip)
	}
	return e.verdict, nil
}

func TestCollector_OnlyEmitsNetNew(t *testing.T) {
	now := time.Now().UTC()
	ftch := &fakeFetcher{
		outages: cfradar.OutageResultBody{
			Annotations: []cfradar.OutageAnnotation{
				{ID: "out-known", StartDate: now},
				{ID: "out-new", StartDate: now},
			},
		},
		hijacks: cfradar.HijackBody{Events: []cfradar.HijackEvent{
			{ID: 100, DetectedAt: now, StartedAt: now, Confidence: 9},
			{ID: 200, DetectedAt: now, StartedAt: now, Confidence: 8},
		}},
	}
	repo := &fakeRepo{
		knownOutages: map[string]bool{"out-known": true},
		knownHijacks: map[int64]bool{200: true},
	}
	emt := &fakeEmitter{}

	c := cfradar.NewCollector(cfradar.CollectorConfig{
		Interval:      30 * time.Millisecond,
		MinConfidence: 7,
		Fetcher:       ftch,
		Repo:          repo,
		Emitter:       emt,
		State:         noopState{},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	evs := emt.Events()

	var outageEvents, hijackEvents int
	for _, ev := range evs {
		switch ev.Topic {
		case events.TopicInternetOutage:
			outageEvents++
			body, _ := json.Marshal(ev.Payload)
			require.Contains(t, string(body), "out-new")
			require.NotContains(t, string(body), "out-known")
		case events.TopicBGPHijack:
			hijackEvents++
			body, _ := json.Marshal(ev.Payload)
			require.Contains(t, string(body), "100")
		}
	}
	require.GreaterOrEqual(t, outageEvents, 1)
	require.GreaterOrEqual(t, hijackEvents, 1)
}

func TestCollector_EnrichesHijackPayloadWhenEnricherProvided(t *testing.T) {
	now := time.Now().UTC()
	ftch := &fakeFetcher{
		hijacks: cfradar.HijackBody{Events: []cfradar.HijackEvent{
			{
				ID:          501,
				DetectedAt:  now,
				StartedAt:   now,
				Confidence:  9,
				HijackerASN: 4242,
				Prefixes:    []string{"203.0.113.0/24"},
			},
		}},
	}
	repo := &fakeRepo{knownHijacks: map[int64]bool{}}
	emt := &fakeEmitter{}
	enr := &fakeEnricher{verdict: cfradar.Enrichment{
		Country:         "RU",
		AbuseConfidence: 95,
		ISP:             "ExampleNet",
	}}

	c := cfradar.NewCollector(cfradar.CollectorConfig{
		Interval:      30 * time.Millisecond,
		MinConfidence: 7,
		Fetcher:       ftch,
		Repo:          repo,
		Emitter:       emt,
		State:         noopState{},
		Enricher:      enr,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(t, enr.calls, 1)
	require.Equal(t, "203.0.113.0", enr.lastIP)

	var found bool
	for _, ev := range emt.Events() {
		if ev.Topic != events.TopicBGPHijack {
			continue
		}
		body, _ := json.Marshal(ev.Payload)
		require.Contains(t, string(body), `"country":"RU"`)
		require.Contains(t, string(body), `"abuse_confidence":95`)
		require.Contains(t, string(body), `"checked_ip":"203.0.113.0"`)
		found = true
	}
	require.True(t, found, "expected at least one hijack event with enrichment")
}

func TestCollector_HijackEmitsRawWhenNoEnricher(t *testing.T) {
	now := time.Now().UTC()
	ftch := &fakeFetcher{
		hijacks: cfradar.HijackBody{Events: []cfradar.HijackEvent{
			{
				ID:         777,
				DetectedAt: now,
				StartedAt:  now,
				Confidence: 9,
				Prefixes:   []string{"198.51.100.0/24"},
			},
		}},
	}
	repo := &fakeRepo{knownHijacks: map[int64]bool{}}
	emt := &fakeEmitter{}

	c := cfradar.NewCollector(cfradar.CollectorConfig{
		Interval:      30 * time.Millisecond,
		MinConfidence: 7,
		Fetcher:       ftch,
		Repo:          repo,
		Emitter:       emt,
		State:         noopState{},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	for _, ev := range emt.Events() {
		if ev.Topic != events.TopicBGPHijack {
			continue
		}
		body, _ := json.Marshal(ev.Payload)
		require.NotContains(t, string(body), `"enrichment"`)
	}
}

func TestCollector_RepeatedTickIsIdempotent(t *testing.T) {
	now := time.Now().UTC()
	ftch := &fakeFetcher{
		outages: cfradar.OutageResultBody{
			Annotations: []cfradar.OutageAnnotation{
				{ID: "out-x", StartDate: now},
			},
		},
	}
	emit := &fakeEmitter{}

	known := map[string]bool{}
	repo := &fakeRepo{knownOutages: known}

	c := cfradar.NewCollector(cfradar.CollectorConfig{
		Interval:      20 * time.Millisecond,
		MinConfidence: 7,
		Fetcher:       ftch,
		Repo:          repo,
		Emitter:       emit,
		State:         noopState{},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		25*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)
	known["out-x"] = true

	emit2 := &fakeEmitter{}
	c2 := cfradar.NewCollector(cfradar.CollectorConfig{
		Interval:      20 * time.Millisecond,
		MinConfidence: 7,
		Fetcher:       ftch,
		Repo:          repo,
		Emitter:       emit2,
		State:         noopState{},
	})
	ctx2, cancel2 := context.WithTimeout(
		context.Background(),
		25*time.Millisecond,
	)
	defer cancel2()
	_ = c2.Run(ctx2)

	for _, ev := range emit2.Events() {
		require.NotEqual(
			t,
			events.TopicInternetOutage,
			ev.Topic,
			"should not re-emit known outage",
		)
	}
}
