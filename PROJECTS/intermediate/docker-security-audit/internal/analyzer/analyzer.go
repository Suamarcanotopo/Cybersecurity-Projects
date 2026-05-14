/*
©AngelaMos | 2026
analyzer.go

Analyzer interface and CIS category constants shared by all analyzer
implementations

Analyzer is the common interface implemented by ContainerAnalyzer,
DaemonAnalyzer, ImageAnalyzer, DockerfileAnalyzer, and ComposeAnalyzer.
The Category constants align with CIS Docker Benchmark sections and
appear on every finding produced in this package.

Key exports:
  Analyzer - interface with Name() and Analyze(ctx) (finding.Collection,
error)
  Result - findings and error from a single analyzer run
  Category - string type for CIS-aligned finding categories

Connects to:
  scanner.go - builds and runs a []Analyzer
  container.go, daemon.go, image.go, dockerfile.go, compose.go - implement
Analyzer
*/

package analyzer

import (
	"context"

	"github.com/CarterPerez-dev/docksec/internal/finding"
)

// Analyzer defines the interface for security analyzers that inspect
// Docker environments and produce security findings.
type Analyzer interface {
	Name() string
	Analyze(ctx context.Context) (finding.Collection, error)
}

// Result holds the output of a single analyzer run, including any
// findings discovered and any error encountered during analysis.
type Result struct {
	Analyzer string
	Findings finding.Collection
	Error    error
}

// Category represents a grouping for security findings, typically
// aligned with CIS Docker Benchmark sections.
type Category string

// Categories for organizing security findings by CIS Docker Benchmark section.
const (
	CategoryContainerRuntime Category = "Container Runtime"
	CategoryDaemon           Category = "Docker Daemon Configuration"
	CategoryImage            Category = "Container Images and Build Files"
	CategoryDockerfile       Category = "Dockerfile"
	CategoryCompose          Category = "Docker Compose"
)
