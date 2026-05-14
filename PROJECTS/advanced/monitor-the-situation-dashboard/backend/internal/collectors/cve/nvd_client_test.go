// ©AngelaMos | 2026
// nvd_client_test.go

package cve_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cve"
)

func TestNVDClient_FetchSendsAPIKeyAndDecodes(t *testing.T) {
	var sawKey, sawStart, sawEnd string
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			sawKey = r.Header.Get("apiKey")
			sawStart = r.URL.Query().Get("lastModStartDate")
			sawEnd = r.URL.Query().Get("lastModEndDate")
			body, err := os.ReadFile("testdata/nvd_2h_window.json")
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		}),
	)
	defer srv.Close()

	c := cve.NewNVDClient(
		cve.NVDClientConfig{BaseURL: srv.URL, APIKey: "test-key"},
	)

	end := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	start := end.Add(-2 * time.Hour)

	resp, err := c.Fetch(context.Background(), start, end)
	require.NoError(t, err)
	require.NotEmpty(t, resp.Vulnerabilities)
	require.Equal(t, "test-key", sawKey)
	require.NotEmpty(t, sawStart)
	require.NotEmpty(t, sawEnd)
}

func TestNVDClient_PrimarySeverityFromV31(t *testing.T) {
	v := cve.NVDVulnRoot{CVE: cve.NVDCVE{
		ID: "CVE-2026-X",
		Metrics: cve.NVDMetrics{
			CVSSv31: []cve.NVDMetricEntry{
				{
					CVSSData: cve.NVDCVSSData{
						BaseScore:    9.8,
						BaseSeverity: "CRITICAL",
					},
				},
			},
		},
	}}
	score, sev := v.PrimarySeverity()
	require.InDelta(t, 9.8, score, 0.0001)
	require.Equal(t, "CRITICAL", sev)
}

func TestNVDClient_PrimarySeverityFallsBackToV30(t *testing.T) {
	v := cve.NVDVulnRoot{CVE: cve.NVDCVE{
		ID: "CVE-2018-X",
		Metrics: cve.NVDMetrics{
			CVSSv30: []cve.NVDMetricEntry{
				{
					CVSSData: cve.NVDCVSSData{
						BaseScore:    7.5,
						BaseSeverity: "HIGH",
					},
				},
			},
		},
	}}
	score, sev := v.PrimarySeverity()
	require.InDelta(t, 7.5, score, 0.0001)
	require.Equal(t, "HIGH", sev)
}

func TestNVDClient_PrimarySeverityZeroWhenMissing(t *testing.T) {
	v := cve.NVDVulnRoot{CVE: cve.NVDCVE{ID: "CVE-X"}}
	score, sev := v.PrimarySeverity()
	require.Zero(t, score)
	require.Empty(t, sev)
}

// TestNVDClient_FetchPaginatesAcrossMultiplePages: NVD caps a single
// response at 2000 vulns. With a window like Patch Tuesday that exceeds
// that, we have to walk startIndex until startIndex >= totalResults.
// Pre-fix the collector silently dropped everything past page 1.
func TestNVDClient_FetchPaginatesAcrossMultiplePages(t *testing.T) {
	const total = 4500
	var hits atomic.Int32

	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			hits.Add(1)
			startIdx, _ := strconv.Atoi(r.URL.Query().Get("startIndex"))
			perPage, _ := strconv.Atoi(r.URL.Query().Get("resultsPerPage"))
			if perPage <= 0 {
				perPage = 2000
			}
			end := startIdx + perPage
			if end > total {
				end = total
			}
			vulns := make([]cve.NVDVulnRoot, 0, end-startIdx)
			for i := startIdx; i < end; i++ {
				vulns = append(vulns, cve.NVDVulnRoot{
					CVE: cve.NVDCVE{ID: fmt.Sprintf("CVE-2026-%05d", i)},
				})
			}
			resp := cve.NVDResponse{
				ResultsPerPage:  perPage,
				StartIndex:      startIdx,
				TotalResults:    total,
				Vulnerabilities: vulns,
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(resp)
		}),
	)
	defer srv.Close()

	c := cve.NewNVDClient(cve.NVDClientConfig{BaseURL: srv.URL})
	end := time.Now().UTC()
	start := end.Add(-2 * time.Hour)

	resp, err := c.Fetch(context.Background(), start, end)
	require.NoError(t, err)
	require.Len(t, resp.Vulnerabilities, total, "every page should be combined")
	require.Equal(t, total, resp.TotalResults)
	require.GreaterOrEqual(
		t,
		hits.Load(),
		int32(3),
		"4500/2000 needs >=3 page calls",
	)
}
