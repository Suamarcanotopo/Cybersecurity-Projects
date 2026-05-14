// ©AngelaMos | 2026
// StatusFooter.tsx

import { useEffect, useState } from 'react'
import { type SourceKey, useFreshness } from '@/stores/freshness'
import { useUIStore } from '@/stores/ui'
import styles from './StatusFooter.module.scss'

const TICK_MS = 1_000
const LIVE_THRESHOLD_MS = 5_000
const AGE_BUCKET_MS = 5_000

interface SourceSpec {
  key: SourceKey
  label: string
  staleAfterMs: number
  batch: boolean
  hint: string
}

const SOURCES: readonly SourceSpec[] = [
  {
    key: 'ws',
    label: 'WS',
    staleAfterMs: 10_000,
    batch: false,
    hint: 'WebSocket heartbeat',
  },
  {
    key: 'btc',
    label: 'BTC',
    staleAfterMs: 90_000,
    batch: false,
    hint: 'Coinbase WS · real-time',
  },
  {
    key: 'eth',
    label: 'ETH',
    staleAfterMs: 90_000,
    batch: false,
    hint: 'Coinbase WS · real-time',
  },
  {
    key: 'iss',
    label: 'ISS',
    staleAfterMs: 60_000,
    batch: false,
    hint: 'wheretheiss.at · real-time',
  },
  {
    key: 'spacewx',
    label: 'SWPC',
    staleAfterMs: 900_000,
    batch: true,
    hint: 'NOAA SWPC · polls every 1m (Kp/plasma) · 3h (X-ray)',
  },
  {
    key: 'quake',
    label: 'USGS',
    staleAfterMs: 600_000,
    batch: true,
    hint: 'USGS earthquake feed · polls every 1m',
  },
  {
    key: 'cve',
    label: 'NVD',
    staleAfterMs: 900_000,
    batch: true,
    hint: 'NVD CVE 2.0 · polls every 2h',
  },
  {
    key: 'kev',
    label: 'KEV',
    staleAfterMs: 86_400_000,
    batch: true,
    hint: 'CISA KEV catalog · polls every 1h',
  },
  {
    key: 'ransomware',
    label: 'RANSOM',
    staleAfterMs: 3_600_000,
    batch: true,
    hint: 'ransomware.live · polls every 15m',
  },
  {
    key: 'bgp',
    label: 'BGP',
    staleAfterMs: 600_000,
    batch: true,
    hint: 'Cloudflare Radar · polls every 5m',
  },
  {
    key: 'outage',
    label: 'OUTAGE',
    staleAfterMs: 1_800_000,
    batch: true,
    hint: 'Cloudflare Radar · polls every 5m',
  },
  {
    key: 'dshield',
    label: 'DSHIELD',
    staleAfterMs: 300_000,
    batch: true,
    hint: 'DShield / ISC SANS · polls every 1h',
  },
  {
    key: 'wiki',
    label: 'WIKI',
    staleAfterMs: 3_600_000,
    batch: true,
    hint: 'Wikipedia ITN · polls every 5m',
  },
] as const

const MS_PER_S = 1_000
const S_PER_M = 60
const S_PER_H = 3_600

export function StatusFooter(): React.ReactElement | null {
  const ts = useFreshness((s) => s.ts)
  const isPresentation = useUIStore((s) => s.presentationMode)
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), TICK_MS)
    return () => clearInterval(id)
  }, [])

  if (isPresentation) return null

  return (
    <footer className={styles.bar}>
      <span className={styles.brand}>SOURCE FEED</span>
      <span className={styles.sep} aria-hidden>
        ·
      </span>
      <span className={styles.list}>
        {SOURCES.map((src) => {
          const last = ts[src.key]
          const age = last ? now - last : null
          const stale =
            last === undefined
              ? !src.batch
              : age !== null && age > src.staleAfterMs
          const dotCls = stale
            ? `${styles.dot} ${styles.stale}`
            : src.batch
              ? `${styles.dot} ${styles.batch}`
              : `${styles.dot} ${styles.live}`
          const isLive =
            !stale && !src.batch && age !== null && age < LIVE_THRESHOLD_MS
          return (
            <span key={src.key} className={styles.entry}>
              <span className={dotCls} aria-hidden />
              <span className={styles.label} title={src.hint}>
                {src.label}
              </span>
              <span className={isLive ? styles.liveText : styles.age}>
                {isLive ? 'live' : fmtAge(age)}
              </span>
            </span>
          )
        })}
      </span>
      <span className={styles.legend} aria-hidden="true">
        <span className={`${styles.legendDot} ${styles.live}`} aria-hidden />
        <span className={styles.legendLabel}>live</span>
        <span className={styles.legendSep} aria-hidden>
          ·
        </span>
        <span className={`${styles.legendDot} ${styles.batch}`} aria-hidden />
        <span className={styles.legendLabel}>batch</span>
        <span className={styles.legendSep} aria-hidden>
          ·
        </span>
        <span className={`${styles.legendDot} ${styles.stale}`} aria-hidden />
        <span className={styles.legendLabel}>stale</span>
      </span>
    </footer>
  )
}

StatusFooter.displayName = 'StatusFooter'

function fmtAge(ms: number | null): string {
  if (ms === null || !Number.isFinite(ms) || ms < 0) return '—'
  const bucketed = Math.floor(ms / AGE_BUCKET_MS) * AGE_BUCKET_MS
  const s = Math.floor(bucketed / MS_PER_S)
  if (s < S_PER_M) return `${s}s`
  if (s < S_PER_H) return `${Math.floor(s / S_PER_M)}m`
  return `${Math.floor(s / S_PER_H)}h`
}
