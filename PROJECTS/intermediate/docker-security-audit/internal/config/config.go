/*
©AngelaMos | 2026
config.go

Scan configuration struct and target-selection helpers

Config holds all CLI options passed to docksec and exposes methods
for interpreting them. Scan targets (containers, daemon, images,
files) are resolved here so the rest of the pipeline doesn't parse
strings. Severity filtering and fail-on threshold logic lives here
as well.

Key exports:
  Config - scan options including targets, severity filters, and output
  New - creates Config with sensible defaults

Connects to:
  finding.go - resolves severity strings to Severity values
  constants.go - reads DefaultWorkerCount
  main.go - fields populated from cobra flags
  scanner.go - passed to Scanner on construction
*/

package config

import "github.com/CarterPerez-dev/docksec/internal/finding"

type Config struct {
	Targets           []string
	Files             []string
	Output            string
	OutputFile        string
	Severity          []string
	CISControls       []string
	ExcludeContainers []string
	IncludeContainers []string
	FailOn            string
	Quiet             bool
	Verbose           bool
	Workers           int
}

func New() *Config {
	return &Config{
		Targets: []string{"all"},
		Output:  "terminal",
		Workers: DefaultWorkerCount,
	}
}

func (c *Config) ShouldScanContainers() bool {
	return c.containsTarget("all") || c.containsTarget("containers")
}

func (c *Config) ShouldScanDaemon() bool {
	return c.containsTarget("all") || c.containsTarget("daemon")
}

func (c *Config) ShouldScanImages() bool {
	return c.containsTarget("all") || c.containsTarget("images")
}

func (c *Config) HasFileTargets() bool {
	return len(c.Files) > 0
}

func (c *Config) containsTarget(target string) bool {
	for _, t := range c.Targets {
		if t == target {
			return true
		}
	}
	return false
}

func (c *Config) GetFailOnSeverity() (finding.Severity, bool) {
	if c.FailOn == "" {
		return finding.SeverityInfo, false
	}
	sev, ok := finding.ParseSeverity(c.FailOn)
	return sev, ok
}

func (c *Config) GetSeverityFilters() []finding.Severity {
	if len(c.Severity) == 0 {
		return nil
	}
	var severities []finding.Severity
	for _, s := range c.Severity {
		if sev, ok := finding.ParseSeverity(s); ok {
			severities = append(severities, sev)
		}
	}
	return severities
}

func (c *Config) ShouldIncludeSeverity(sev finding.Severity) bool {
	filters := c.GetSeverityFilters()
	if len(filters) == 0 {
		return true
	}
	for _, f := range filters {
		if f == sev {
			return true
		}
	}
	return false
}
