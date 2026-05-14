// ©AngelaMos | 2026
// collector_test.go

package cve_test

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cve"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type stubNVD struct {
	resp cve.NVDResponse
	err  error
}

func (s *stubNVD) Fetch(
	context.Context,
	time.Time,
	time.Time,
) (cve.NVDResponse, error) {
	return s.resp, s.err
}

type stubEPSS struct {
	scores map[string]cve.EPSSScore
	err    error
}

func (s *stubEPSS) LookupBatch(
	context.Context,
	[]string,
) (map[string]cve.EPSSScore, error) {
	return s.scores, s.err
}

type stubCVERepo struct {
	mu      sync.Mutex
	upserts map[string]cve.Row
	patches map[string][2]float64
}

func newStubCVERepo() *stubCVERepo {
	return &stubCVERepo{
		upserts: map[string]cve.Row{},
		patches: map[string][2]float64{},
	}
}

func (r *stubCVERepo) Upsert(_ context.Context, row cve.Row) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.upserts[row.CveID] = row
	return nil
}

func (r *stubCVERepo) UpdateEPSS(
	_ context.Context,
	id string,
	score, pct float64,
) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.patches[id] = [2]float64{score, pct}
	return nil
}

func (r *stubCVERepo) Upserts() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.upserts)
}

func (r *stubCVERepo) Patches() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.patches)
}

type stubCVEEmitter struct {
	mu     sync.Mutex
	events []events.Event
}

func (e *stubCVEEmitter) Emit(ev events.Event) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.events = append(e.events, ev)
}

func (e *stubCVEEmitter) Events() []events.Event {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]events.Event, len(e.events))
	copy(out, e.events)
	return out
}

type stubCVEState struct{}

func (stubCVEState) RecordSuccess(context.Context, string, int64) {}
func (stubCVEState) RecordError(context.Context, string, string)  {}

func TestCVECollector_FetchesEnrichesAndEmits(t *testing.T) {
	now := time.Now().UTC()
	nvd := &stubNVD{resp: cve.NVDResponse{
		Vulnerabilities: []cve.NVDVulnRoot{
			{CVE: cve.NVDCVE{
				ID:           "CVE-2026-0001",
				Published:    cve.NVDTime{Time: now.Add(-time.Hour)},
				LastModified: cve.NVDTime{Time: now},
				Metrics: cve.NVDMetrics{CVSSv31: []cve.NVDMetricEntry{
					{
						CVSSData: cve.NVDCVSSData{
							BaseScore:    9.8,
							BaseSeverity: "CRITICAL",
						},
					},
				}},
			}},
			{CVE: cve.NVDCVE{
				ID:           "CVE-2026-0002",
				Published:    cve.NVDTime{Time: now.Add(-time.Hour)},
				LastModified: cve.NVDTime{Time: now},
			}},
		},
	}}
	epss := &stubEPSS{scores: map[string]cve.EPSSScore{
		"CVE-2026-0001": {CveID: "CVE-2026-0001", Score: 0.9, Percentile: 0.99},
		"CVE-2026-0002": {CveID: "CVE-2026-0002", Score: 0.1, Percentile: 0.5},
	}}
	repo := newStubCVERepo()
	emt := &stubCVEEmitter{}

	c := cve.NewCollector(cve.CollectorConfig{
		Interval: 30 * time.Millisecond,
		NVD:      nvd,
		EPSS:     epss,
		Repo:     repo,
		Emitter:  emt,
		State:    stubCVEState{},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(t, repo.Upserts(), 2)
	require.GreaterOrEqual(t, repo.Patches(), 2)

	evs := emt.Events()
	require.GreaterOrEqual(t, len(evs), 2)
	for _, ev := range evs {
		require.Equal(t, events.TopicCVENew, ev.Topic)
		require.Equal(t, cve.Name, ev.Source)
		raw, ok := ev.Payload.(json.RawMessage)
		require.True(t, ok)
		require.Contains(t, string(raw), "CVE-2026-")
	}
}

func TestCVECollector_NVDFetchErrorRecordsState(t *testing.T) {
	nvd := &stubNVD{err: context.DeadlineExceeded}
	repo := newStubCVERepo()
	emt := &stubCVEEmitter{}

	c := cve.NewCollector(cve.CollectorConfig{
		Interval: 20 * time.Millisecond,
		NVD:      nvd,
		EPSS:     &stubEPSS{},
		Repo:     repo,
		Emitter:  emt,
		State:    stubCVEState{},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		30*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.Zero(t, repo.Upserts())
	require.Zero(t, repo.Patches())
	require.Empty(t, emt.Events())
}
