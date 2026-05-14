// ©AngelaMos | 2026
// collector_test.go

package wikipedia_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/wikipedia"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type fakeFetcher struct {
	resp wikipedia.Response
	err  error
}

func (f *fakeFetcher) Fetch(_ context.Context) (wikipedia.Response, error) {
	return f.resp, f.err
}

type fakeRepo struct {
	mu        sync.Mutex
	revID     int64
	revKnown  bool
	inserts   []wikipedia.Entry
	saveCalls int
}

func (r *fakeRepo) RememberRevID(_ context.Context, revID int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.revID = revID
	r.revKnown = true
	r.saveCalls++
	return nil
}

func (r *fakeRepo) LastRevID(_ context.Context) (int64, bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.revID, r.revKnown, nil
}

func (r *fakeRepo) Insert(_ context.Context, e wikipedia.Entry) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.inserts = append(r.inserts, e)
	return nil
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

func TestCollector_NewRevidInsertsAndEmits(t *testing.T) {
	resp := wikipedia.Response{
		RevID: 999,
		HTML: `<ul>` +
			`<li>A long enough ITN headline mentioning <a href="/wiki/A">subject A</a> for context.</li>` +
			`<li>Another long enough ITN headline referencing <a href="/wiki/B">subject B</a> in the news.</li>` +
			`</ul>`,
	}
	ftch := &fakeFetcher{resp: resp}
	repo := &fakeRepo{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := wikipedia.NewCollector(wikipedia.CollectorConfig{
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

	require.GreaterOrEqual(t, repo.Inserts(), 2)
	require.GreaterOrEqual(t, emt.Count(), 2)
	for _, ev := range emt.events {
		require.Equal(t, events.TopicWikipediaITN, ev.Topic)
	}
	require.Positive(t, st.successes)
}

func TestCollector_RevIDUnchangedSkipsInsert(t *testing.T) {
	resp := wikipedia.Response{
		RevID: 555,
		HTML:  `<ul><li>Story <a href="/wiki/X">link</a></li></ul>`,
	}
	ftch := &fakeFetcher{resp: resp}
	repo := &fakeRepo{revID: 555, revKnown: true}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := wikipedia.NewCollector(wikipedia.CollectorConfig{
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

	require.Equal(t, 0, repo.Inserts())
	require.Equal(t, 0, emt.Count())
	require.Positive(t, st.successes)
}

func TestCollector_FetchErrorRecordsState(t *testing.T) {
	ftch := &fakeFetcher{err: errors.New("upstream 503")}
	repo := &fakeRepo{}
	emt := &fakeEmitter{}
	st := &recordingState{}

	c := wikipedia.NewCollector(wikipedia.CollectorConfig{
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

	require.Equal(t, 0, repo.Inserts())
	require.Positive(t, st.failures)
}
