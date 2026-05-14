// ©AngelaMos | 2026
// EarthquakePanel.tsx

import { useEffect, useRef, useState } from 'react'
import { useEarthquakeData } from '@/api/hooks'
import { useFreshness } from '@/stores/freshness'
import styles from './EarthquakePanel.module.scss'
import { Panel } from './Panel'

const QUAKE_ROW_LIMIT = 8
const FLASH_DURATION_MS = 600
const STALE_AFTER_MS = 600_000
const MS_PER_HOUR = 3_600_000
const MS_PER_MINUTE = 60_000
const HOURS_PER_DAY = 24

export function EarthquakePanel(): React.ReactElement {
  const { items } = useEarthquakeData()
  const seenIds = useRef<Set<string>>(new Set())
  const [flashIds, setFlashIds] = useState<Set<string>>(new Set())

  useEffect(() => {
    const isFirstSeed = seenIds.current.size === 0
    const newIds: string[] = []
    for (const q of items) {
      if (!seenIds.current.has(q.id)) {
        seenIds.current.add(q.id)
        if (!isFirstSeed) newIds.push(q.id)
      }
    }
    if (newIds.length > 0) setFlashIds(new Set(newIds))
  }, [items])

  useEffect(() => {
    if (flashIds.size === 0) return
    const t = setTimeout(() => setFlashIds(new Set()), FLASH_DURATION_MS)
    return () => clearTimeout(t)
  }, [flashIds])

  const recent = items.slice(0, QUAKE_ROW_LIMIT)
  const now = Date.now()

  const lastTickAt = useFreshness((s) => s.ts.quake)
  const isStale =
    items.length === 0
      ? undefined
      : lastTickAt !== undefined && Date.now() - lastTickAt > STALE_AFTER_MS

  return (
    <Panel
      title="USGS"
      subtitle="QUAKES"
      source="usgs feed"
      accent="quake"
      rawHref="https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson"
      rawLabel="USGS feed"
      isStale={isStale}
      lastTickAt={lastTickAt}
      batch
    >
      <table className={styles.table}>
        <thead>
          <tr>
            <th className={styles.mag}>Mag</th>
            <th className={styles.place}>Place</th>
            <th className={styles.ago}>Ago</th>
          </tr>
        </thead>
        <tbody>
          {recent.map((q) => {
            const isFlashing = flashIds.has(q.id)
            return (
              <tr key={q.id} className={isFlashing ? styles.flash : undefined}>
                <td className={styles.mag}>{fmtMag(q.properties?.mag)}</td>
                <td className={styles.place} title={q.properties?.place ?? ''}>
                  {q.properties?.place ?? '—'}
                </td>
                <td className={styles.ago}>{fmtAgo(q.properties?.time, now)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </Panel>
  )
}

EarthquakePanel.displayName = 'EarthquakePanel'

function fmtMag(mag: number | null | undefined): string {
  if (mag === null || mag === undefined) return '—'
  return mag.toFixed(1)
}

function fmtAgo(ts: number | undefined, now: number): string {
  if (!ts) return '—'
  const diff = now - ts
  if (diff < 0) return '—'
  if (diff < MS_PER_HOUR) {
    return `${Math.max(Math.floor(diff / MS_PER_MINUTE), 0)}m`
  }
  if (diff < HOURS_PER_DAY * MS_PER_HOUR) {
    return `${Math.floor(diff / MS_PER_HOUR)}h`
  }
  return `${Math.floor(diff / (HOURS_PER_DAY * MS_PER_HOUR))}d`
}
