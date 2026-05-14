// ©AngelaMos | 2026
// types.go

package dshield

type RawSource struct {
	Rank    int    `json:"rank"`
	Source  string `json:"source"`
	Reports int    `json:"reports"`
	Targets int    `json:"targets"`
}

type EnrichedSource struct {
	Rank           int    `json:"rank"`
	Source         string `json:"source"`
	Reports        int    `json:"reports"`
	Targets        int    `json:"targets"`
	Country        string `json:"country,omitempty"`
	Classification string `json:"classification,omitempty"`
	Actor          string `json:"actor,omitempty"`
}
