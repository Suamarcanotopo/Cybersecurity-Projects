// ©AngelaMos | 2026
// propagator.go

package iss

import (
	"fmt"
	"math"
	"strings"
	"time"

	satellite "github.com/joshuaferrara/go-satellite"
)

type Sat struct {
	inner satellite.Satellite
}

func LoadTLE(line1, line2 string) (Sat, error) {
	if !strings.HasPrefix(line1, "1 ") || !strings.HasPrefix(line2, "2 ") {
		return Sat{}, fmt.Errorf(
			"invalid TLE: lines must start with '1 ' and '2 '",
		)
	}
	s := satellite.TLEToSat(line1, line2, satellite.GravityWGS84)
	if s.Error != 0 || s.ErrorStr != "" {
		return Sat{}, fmt.Errorf(
			"parse TLE: error %d / %s",
			s.Error,
			s.ErrorStr,
		)
	}
	return Sat{inner: s}, nil
}

func Propagate(s Sat, t time.Time) (lat, lon, altKm float64) {
	t = t.UTC()
	pos, _ := satellite.Propagate(
		s.inner,
		t.Year(),
		int(t.Month()),
		t.Day(),
		t.Hour(),
		t.Minute(),
		t.Second(),
	)
	gmst := satellite.GSTimeFromDate(
		t.Year(),
		int(t.Month()),
		t.Day(),
		t.Hour(),
		t.Minute(),
		t.Second(),
	)
	altitude, _, ll := satellite.ECIToLLA(pos, gmst)
	deg := satellite.LatLongDeg(ll)
	return deg.Latitude, deg.Longitude, altitude
}

func LookAngles(
	s Sat,
	t time.Time,
	observerLatDeg, observerLonDeg, observerAltKm float64,
) (azimuthDeg, elevationDeg, rangeKm float64) {
	t = t.UTC()
	pos, _ := satellite.Propagate(
		s.inner,
		t.Year(),
		int(t.Month()),
		t.Day(),
		t.Hour(),
		t.Minute(),
		t.Second(),
	)
	jday := satellite.JDay(
		t.Year(),
		int(t.Month()),
		t.Day(),
		t.Hour(),
		t.Minute(),
		t.Second(),
	)
	obs := satellite.LatLong{
		Latitude:  observerLatDeg * math.Pi / 180,
		Longitude: observerLonDeg * math.Pi / 180,
	}
	la := satellite.ECIToLookAngles(pos, obs, observerAltKm, jday)
	return la.Az * 180 / math.Pi, la.El * 180 / math.Pi, la.Rg
}
