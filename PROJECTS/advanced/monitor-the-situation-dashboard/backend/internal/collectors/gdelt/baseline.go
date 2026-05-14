// ©AngelaMos | 2026
// baseline.go

package gdelt

import "math"

const (
	minStdDev = 1.0
)

type Bucket struct {
	Score int64
	Count int
}

type ThemeState struct {
	buckets []Bucket
	capN    int
}

func NewThemeState(capN int) *ThemeState {
	if capN <= 0 {
		capN = 96
	}
	return &ThemeState{capN: capN}
}

func (s *ThemeState) Push(b Bucket) {
	s.buckets = append(s.buckets, b)
	if len(s.buckets) > s.capN {
		s.buckets = s.buckets[len(s.buckets)-s.capN:]
	}
}

func (s *ThemeState) Len() int {
	return len(s.buckets)
}

func (s *ThemeState) Stats() (mean, stddev float64) {
	if len(s.buckets) == 0 {
		return 0, 0
	}
	sum := 0.0
	for _, b := range s.buckets {
		sum += float64(b.Count)
	}
	mean = sum / float64(len(s.buckets))

	variance := 0.0
	for _, b := range s.buckets {
		d := float64(b.Count) - mean
		variance += d * d
	}
	variance /= float64(len(s.buckets))
	stddev = math.Sqrt(variance)
	return mean, stddev
}

func (s *ThemeState) ZScore(count int) float64 {
	mean, stddev := s.Stats()
	if stddev < minStdDev {
		return 0
	}
	return (float64(count) - mean) / stddev
}
