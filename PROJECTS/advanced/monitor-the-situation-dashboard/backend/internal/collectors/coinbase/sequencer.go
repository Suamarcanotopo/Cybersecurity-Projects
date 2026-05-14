// ©AngelaMos | 2026
// sequencer.go

package coinbase

import "sync"

type Sequencer struct {
	mu   sync.Mutex
	last int64
	set  bool
}

func NewSequencer() *Sequencer {
	return &Sequencer{}
}

func (s *Sequencer) Observe(seq int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.set {
		s.last = seq
		s.set = true
		return false
	}
	expected := s.last + 1
	s.last = seq
	return seq != expected
}

func (s *Sequencer) Reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.set = false
	s.last = 0
}
