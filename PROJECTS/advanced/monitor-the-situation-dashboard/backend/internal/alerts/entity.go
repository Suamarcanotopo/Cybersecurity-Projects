// ©AngelaMos | 2026
// entity.go

package alerts

import (
	"encoding/json"
	"time"
)

// Rule mirrors the alert_rules table. Predicate is a CEL expression
// evaluated against {event: <topic payload>}. Empty predicate means
// "always fire" — used for default rules like "every KEV add".
type Rule struct {
	ID          string    `db:"id"`
	UserID      string    `db:"user_id"`
	Name        string    `db:"name"`
	Topic       string    `db:"topic"`
	Predicate   string    `db:"predicate"`
	CooldownSec int       `db:"cooldown_sec"`
	Enabled     bool      `db:"enabled"`
	CreatedAt   time.Time `db:"created_at"`
	UpdatedAt   time.Time `db:"updated_at"`
}

// HistoryRow mirrors alert_history. Used both for delivery audit and so
// the UI can show "last fired".
type HistoryRow struct {
	ID             int64           `db:"id"`
	RuleID         string          `db:"rule_id"`
	UserID         string          `db:"user_id"`
	FiredAt        time.Time       `db:"fired_at"`
	Payload        json.RawMessage `db:"payload"`
	DeliveredTo    []string        `db:"delivered_to"`
	DeliveryErrors json.RawMessage `db:"delivery_errors"`
}

// DefaultRuleSeed is what registers as the bootstrap rule set for a new
// user. The predicates come straight from
// docs/specs/2026-05-01-monitor-the-situation-design.md.
type DefaultRuleSeed struct {
	Name        string
	Topic       string
	Predicate   string
	CooldownSec int
}

// Defaults returns the seed rules. KEV is the highest-priority alarm
// (per spec); CVE filters to severe items only; earthquake / space
// weather use the spec thresholds; ransomware fires on every entry.
// BTC / ETH ride on the `change_pct_1h` field the coinbase collector
// computes from a 1-hour sliding window — `has(...)` guards against
// firing during the warmup period when the window isn't full yet.
// Cooldowns are sized so a sustained crash doesn't spam — 30 min for
// the price drops; you can shorten in the settings UI per-rule.
func Defaults() []DefaultRuleSeed {
	return []DefaultRuleSeed{
		{
			Name:        "KEV: every newly-added entry",
			Topic:       "kev_added",
			Predicate:   "",
			CooldownSec: 0,
		},
		{
			Name:        "CVE: critical (CVSS≥9 or EPSS≥0.95)",
			Topic:       "cve_new",
			Predicate:   "event.CVSS >= 9.0 || (has(event.EPSSPercentile) && event.EPSSPercentile != null && event.EPSSPercentile >= 0.95)",
			CooldownSec: 300,
		},
		{
			Name:        "Earthquake: M6.5+",
			Topic:       "earthquake",
			Predicate:   "event.properties.mag >= 6.5",
			CooldownSec: 60,
		},
		{
			Name:        "Space weather: Kp≥7 or X-class flare",
			Topic:       "space_weather",
			Predicate:   "(has(event.kp) && event.kp >= 7.0) || (has(event.xray_class) && event.xray_class.startsWith('X'))",
			CooldownSec: 3600,
		},
		{
			Name:        "Ransomware: every new victim",
			Topic:       "ransomware_victim",
			Predicate:   "",
			CooldownSec: 60,
		},
		{
			Name:        "BGP hijack: confidence≥9",
			Topic:       "bgp_hijack",
			Predicate:   "event.confidenceScore >= 9",
			CooldownSec: 300,
		},
		{
			Name:        "BTC: 1h drop ≥5%",
			Topic:       "coinbase_price",
			Predicate:   "event.symbol == 'BTC-USD' && has(event.change_pct_1h) && event.change_pct_1h <= -5.0",
			CooldownSec: 1800,
		},
		{
			Name:        "ETH: 1h drop ≥5%",
			Topic:       "coinbase_price",
			Predicate:   "event.symbol == 'ETH-USD' && has(event.change_pct_1h) && event.change_pct_1h <= -5.0",
			CooldownSec: 1800,
		},
	}
}
