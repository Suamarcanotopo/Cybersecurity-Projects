// ©AngelaMos | 2026
// topic.go

package events

type Topic string

const (
	TopicHeartbeat        Topic = "heartbeat"
	TopicScanFirehose     Topic = "scan_firehose"
	TopicInternetOutage   Topic = "internet_outage"
	TopicBGPHijack        Topic = "bgp_hijack"
	TopicCVENew           Topic = "cve_new"
	TopicCVEUpdated       Topic = "cve_updated"
	TopicEPSS             Topic = "epss"
	TopicKEVAdded         Topic = "kev_added"
	TopicRansomwareVictim Topic = "ransomware_victim"
	TopicCoinbasePrice    Topic = "coinbase_price"
	TopicEarthquake       Topic = "earthquake"
	TopicSpaceWeather     Topic = "space_weather"
	TopicWikipediaITN     Topic = "wiki_itn"
	TopicGDELTSpike       Topic = "gdelt_spike"
	TopicISSPosition      Topic = "iss_position"
	TopicCollectorState   Topic = "collector_state"
)

func (t Topic) String() string { return string(t) }

func (t Topic) IsValid() bool {
	switch t {
	case TopicHeartbeat, TopicScanFirehose, TopicInternetOutage, TopicBGPHijack,
		TopicCVENew, TopicCVEUpdated, TopicEPSS, TopicKEVAdded,
		TopicRansomwareVictim, TopicCoinbasePrice, TopicEarthquake,
		TopicSpaceWeather, TopicWikipediaITN, TopicGDELTSpike,
		TopicISSPosition, TopicCollectorState:
		return true
	}
	return false
}

func AllTopics() []Topic {
	return []Topic{
		TopicHeartbeat,
		TopicScanFirehose,
		TopicInternetOutage,
		TopicBGPHijack,
		TopicCVENew,
		TopicCVEUpdated,
		TopicEPSS,
		TopicKEVAdded,
		TopicRansomwareVictim,
		TopicCoinbasePrice,
		TopicEarthquake,
		TopicSpaceWeather,
		TopicWikipediaITN,
		TopicGDELTSpike,
		TopicISSPosition,
		TopicCollectorState,
	}
}
