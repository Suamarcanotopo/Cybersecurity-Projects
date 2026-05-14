// ©AngelaMos | 2026
// Globe.tsx

import { memo, useEffect, useRef, useState } from 'react'
import GlobeGL, { type GlobeMethods } from 'react-globe.gl'
import { useGlobeEvents } from '@/stores/globeEvents'
import { useHeartbeat } from '@/stores/heartbeat'
import styles from './Globe.module.scss'
import { panTo } from './globeCamera'
import { useGlobePoints, useGlobeRings } from './globeLayers'

const GLOBE_AUTO_ROTATE_SPEED = 1.0
const GLOBE_RESUME_DELAY_MS = 3_000
const ATMOSPHERE_COLOR = '#1f2937'
const ATMOSPHERE_ALTITUDE = 0.12
const RING_COLOR = '#e5e5e5'
const RING_MAX_RADIUS = 4
const RING_PROPAGATION_SPEED = 4
const RING_REPEAT_PERIOD = 0
const COUNTRIES_URL = '/world-countries-110m.geo.json'
const COUNTRY_OUTLINE_COLOR = '#404040'
const COUNTRY_FILL_TRANSPARENT = 'rgba(0,0,0,0)'
const COUNTRY_ALTITUDE = 0.005

const LEGEND_ITEMS = [
  { color: '#4ade80', label: 'ISS' },
  { color: '#facc15', label: 'Ransomware' },
  { color: '#f59e0b', label: 'Outage' },
  { color: '#ef4444', label: 'Hijack' },
  { color: '#60a5fa', label: 'Scan' },
  { color: '#a855f7', label: 'Earthquake' },
] as const

interface CountryFeature {
  type: 'Feature'
  properties: Record<string, unknown>
  geometry: {
    type: string
    coordinates: unknown
  }
}

interface CountriesData {
  type: 'FeatureCollection'
  features: CountryFeature[]
}

const GLOBE_DEFAULT_LAT = 15
const GLOBE_DEFAULT_LNG = 10
const GLOBE_DEFAULT_ALTITUDE = 2.5

export const Globe = memo(function Globe(): React.ReactElement {
  const wrapRef = useRef<HTMLDivElement>(null)
  const globeRef = useRef<GlobeMethods | undefined>(undefined)
  const resumeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const viewInitRef = useRef(false)
  const [size, setSize] = useState({ w: 0, h: 0 })
  const [countries, setCountries] = useState<CountryFeature[]>([])

  const points = useGlobePoints()
  const rings = useGlobeRings()
  const focusEvent = useGlobeEvents((s) => s.focusEvent)

  useEffect(() => {
    let cancelled = false
    fetch(COUNTRIES_URL)
      .then((res) => res.json() as Promise<CountriesData>)
      .then((fc) => {
        if (cancelled) return
        setCountries(fc.features)
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    const wrap = wrapRef.current
    if (!wrap) return
    const ro = new ResizeObserver((entries) => {
      const entry = entries[0]
      if (!entry) return
      setSize({
        w: entry.contentRect.width,
        h: entry.contentRect.height,
      })
    })
    ro.observe(wrap)
    return () => ro.disconnect()
  }, [])

  useEffect(() => {
    if (size.w === 0) return
    const globe = globeRef.current
    if (!globe) return

    if (!viewInitRef.current) {
      viewInitRef.current = true
      globe.pointOfView(
        {
          lat: GLOBE_DEFAULT_LAT,
          lng: GLOBE_DEFAULT_LNG,
          altitude: GLOBE_DEFAULT_ALTITUDE,
        },
        0
      )
    }

    const controls = globe.controls()
    if (!controls) return

    controls.autoRotate = true
    controls.autoRotateSpeed = GLOBE_AUTO_ROTATE_SPEED

    const onStart = () => {
      if (resumeTimerRef.current !== null) clearTimeout(resumeTimerRef.current)
      controls.autoRotate = false
    }
    const onEnd = () => {
      resumeTimerRef.current = setTimeout(() => {
        controls.autoRotate = true
      }, GLOBE_RESUME_DELAY_MS)
    }

    controls.addEventListener('start', onStart)
    controls.addEventListener('end', onEnd)

    return () => {
      controls.removeEventListener('start', onStart)
      controls.removeEventListener('end', onEnd)
      if (resumeTimerRef.current !== null) clearTimeout(resumeTimerRef.current)
    }
  }, [size.w])

  useEffect(() => {
    if (!focusEvent) return
    const controls = globeRef.current?.controls()
    if (controls) {
      if (resumeTimerRef.current !== null) clearTimeout(resumeTimerRef.current)
      controls.autoRotate = false
    }
    panTo(globeRef, focusEvent.lat, focusEvent.lng)
  }, [focusEvent])

  return (
    <div ref={wrapRef} className={styles.globeWrap}>
      {size.w > 0 && size.h > 0 && (
        <GlobeGL
          ref={globeRef}
          width={size.w}
          height={size.h}
          polygonsData={countries}
          polygonAltitude={COUNTRY_ALTITUDE}
          polygonCapColor={() => COUNTRY_FILL_TRANSPARENT}
          polygonSideColor={() => COUNTRY_FILL_TRANSPARENT}
          polygonStrokeColor={() => COUNTRY_OUTLINE_COLOR}
          polygonsTransitionDuration={0}
          pointsData={points}
          pointsMerge
          pointLat="lat"
          pointLng="lng"
          pointColor="color"
          pointAltitude="altitude"
          pointRadius="radius"
          ringsData={rings}
          ringLat="lat"
          ringLng="lng"
          ringColor={() => RING_COLOR}
          ringMaxRadius={RING_MAX_RADIUS}
          ringPropagationSpeed={RING_PROPAGATION_SPEED}
          ringRepeatPeriod={RING_REPEAT_PERIOD}
          atmosphereColor={ATMOSPHERE_COLOR}
          atmosphereAltitude={ATMOSPHERE_ALTITUDE}
          backgroundColor="rgba(0,0,0,0)"
        />
      )}
      <div className={styles.dragHint}>drag to rotate</div>
      <div className={styles.legend}>
        {LEGEND_ITEMS.map((item) => (
          <div key={item.label} className={styles.legendRow}>
            <div
              className={styles.legendDot}
              style={{ background: item.color }}
            />
            {item.label}
          </div>
        ))}
      </div>
      <HeartbeatDot />
    </div>
  )
})

const HB_STALE_MS = 12_000

function HeartbeatDot(): React.ReactElement {
  const lastTs = useHeartbeat((s) => s.lastTs)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    const id = setInterval(() => setTick((n) => n + 1), 1_000)
    return () => clearInterval(id)
  }, [])

  void tick
  const isLive = lastTs !== null && Date.now() - lastTs < HB_STALE_MS
  const isConnecting = lastTs === null

  const dotClass = isConnecting
    ? styles.hbConnecting
    : isLive
      ? styles.hbLive
      : styles.hbDead

  const label = isConnecting ? 'CONNECTING' : isLive ? 'LIVE' : 'NO SIGNAL'

  return (
    <div className={styles.hbWrap}>
      <div className={dotClass}>
        {isLive && <div className={styles.hbRing} />}
      </div>
      <span className={styles.hbLabel}>{label}</span>
    </div>
  )
}

Globe.displayName = 'Globe'
