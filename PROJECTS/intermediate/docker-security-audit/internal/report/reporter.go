/*
©AngelaMos | 2026
reporter.go

Reporter interface and factory that dispatches to format-specific
implementations

NewReporter selects and constructs a TerminalReporter, JSONReporter,
SARIFReporter, or JUnitReporter based on the format string. When
outputFile is empty, output goes to stdout. baseReporter holds the
shared writer and closer for the concrete implementations.

Key exports:
  Reporter - interface with Report(findings Collection) error
  NewReporter - factory returning the correct implementation

Connects to:
  scanner.go - calls NewReporter with cfg.Output and cfg.OutputFile
  terminal.go, json.go, sarif.go, junit.go - implement Reporter
  finding.go - Report() accepts finding.Collection
*/

package report

import (
	"fmt"
	"io"
	"os"

	"github.com/CarterPerez-dev/docksec/internal/finding"
)

type Reporter interface {
	Report(findings finding.Collection) error
}

func NewReporter(format, outputFile string) (Reporter, error) {
	var w io.Writer = os.Stdout
	var closer func() error

	if outputFile != "" {
		f, err := os.Create(outputFile)
		if err != nil {
			return nil, fmt.Errorf("creating output file: %w", err)
		}
		w = f
		closer = f.Close
	}

	switch format {
	case "terminal", "":
		return &TerminalReporter{
			w:       w,
			closer:  closer,
			colored: outputFile == "",
		}, nil
	case "json":
		return &JSONReporter{w: w, closer: closer}, nil
	case "sarif":
		return &SARIFReporter{w: w, closer: closer}, nil
	case "junit":
		return &JUnitReporter{w: w, closer: closer}, nil
	default:
		return nil, fmt.Errorf("unsupported output format: %s", format)
	}
}

type baseReporter struct {
	w      io.Writer
	closer func() error
}

func (r *baseReporter) close() error {
	if r.closer != nil {
		return r.closer()
	}
	return nil
}
