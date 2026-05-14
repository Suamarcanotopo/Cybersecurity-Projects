// ©AngelaMos | 2026
// CVEVelocityPanel.tsx

import { useMemo } from 'react'
import { useCveData } from '@/api/hooks'
import type { CveEvent } from '@/api/types'
import { useFreshness } from '@/stores/freshness'
import styles from './CVEVelocityPanel.module.scss'
import { Panel } from './Panel'
import { KPI } from './shared/KPI'
import { Sparkline } from './shared/Sparkline'

const RECENT_ROW_LIMIT = 5
const SPARKLINE_HOURS = 24
const STALE_AFTER_MS = 900_000
const SPARKLINE_WIDTH = 280
const SPARKLINE_HEIGHT = 28
const MS_PER_HOUR = 3_600_000
const MS_PER_MINUTE = 60_000
const HOURS_PER_DAY = 24

export function CVEVelocityPanel(): React.ReactElement {
  const { items } = useCveData()
  const nowMinute = Math.floor(Date.now() / MS_PER_MINUTE) * MS_PER_MINUTE

  const counts = useMemo(() => {
    return {
      h1: countWithin(items, 1, nowMinute),
      h6: countWithin(items, 6, nowMinute),
      h24: countWithin(items, SPARKLINE_HOURS, nowMinute),
    }
  }, [items, nowMinute])

  const hourly = useMemo(
    () => hourlyBuckets(items, SPARKLINE_HOURS, nowMinute),
    [items, nowMinute]
  )

  const recent = items.slice(0, RECENT_ROW_LIMIT)
  const now = Date.now()

  const lastTickAt = useFreshness((s) => s.ts.cve)
  const isStale =
    items.length === 0
      ? undefined
      : lastTickAt !== undefined && Date.now() - lastTickAt > STALE_AFTER_MS

  return (
    <Panel
      title="CVE"
      subtitle="VELOCITY + EPSS"
      source="nvd · first.org"
      accent="cve"
      rawHref="https://nvd.nist.gov/"
      rawLabel="NVD CVE 2.0"
      isStale={isStale}
      lastTickAt={lastTickAt}
      batch
    >
      <div className={styles.kpis}>
        <KPI label="1H" value={counts.h1} />
        <KPI label="6H" value={counts.h6} />
        <KPI label="24H" value={counts.h24} />
      </div>
      <div className={styles.spark}>
        <Sparkline
          data={hourly}
          width={SPARKLINE_WIDTH}
          height={SPARKLINE_HEIGHT}
        />
      </div>
      <table className={styles.recent}>
        <thead>
          <tr>
            <th className={styles.cveId}>CVE</th>
            <th className={styles.severity}>Sev</th>
            <th className={styles.epss}>EPSS</th>
            <th className={styles.ago}>Ago</th>
          </tr>
        </thead>
        <tbody>
          {recent.map((c) => (
            <tr key={c.CveID}>
              <td className={styles.cveId}>{c.CveID}</td>
              <td className={styles.severity}>{c.Severity}</td>
              <td className={styles.epss}>{fmtEpss(c.EPSSPercentile)}</td>
              <td className={styles.ago}>{fmtAgo(c.Published, now)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </Panel>
  )
}

CVEVelocityPanel.displayName = 'CVEVelocityPanel'

function countWithin(items: CveEvent[], hours: number, now: number): number {
  const cutoff = now - hours * MS_PER_HOUR
  return items.reduce((acc, item) => {
    const ts = parseTs(item.Published)
    return ts !== null && ts >= cutoff ? acc + 1 : acc
  }, 0)
}

function hourlyBuckets(items: CveEvent[], hours: number, now: number): number[] {
  const buckets = new Array<number>(hours).fill(0)
  for (const item of items) {
    const ts = parseTs(item.Published)
    if (ts === null) continue
    const hoursAgo = Math.floor((now - ts) / MS_PER_HOUR)
    if (hoursAgo >= 0 && hoursAgo < hours) {
      const idx = hours - 1 - hoursAgo
      buckets[idx] = (buckets[idx] ?? 0) + 1
    }
  }
  return buckets
}

function parseTs(iso: string): number | null {
  const t = new Date(iso).getTime()
  return Number.isFinite(t) ? t : null
}

function fmtEpss(percentile: number | null): string {
  if (percentile === null) return '—'
  return `${(percentile * 100).toFixed(1)}%`
}

function fmtAgo(iso: string, now: number): string {
  const t = parseTs(iso)
  if (t === null) return '—'
  const diffMs = now - t
  if (diffMs < MS_PER_HOUR) {
    const m = Math.floor(diffMs / MS_PER_MINUTE)
    return `${Math.max(m, 0)}m`
  }
  if (diffMs < HOURS_PER_DAY * MS_PER_HOUR) {
    const h = Math.floor(diffMs / MS_PER_HOUR)
    const mins = Math.floor((diffMs % MS_PER_HOUR) / MS_PER_MINUTE)
    return mins > 0 ? `${h}h${mins}m` : `${h}h`
  }
  const d = Math.floor(diffMs / (HOURS_PER_DAY * MS_PER_HOUR))
  return `${d}d`
}
