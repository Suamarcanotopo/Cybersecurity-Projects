// ©AngelaMos | 2026
// OutagePanel.tsx

import { useEffect, useRef, useState } from 'react'
import { useOutageData } from '@/api/hooks'
import { useFreshness } from '@/stores/freshness'
import styles from './OutagePanel.module.scss'
import { Panel } from './Panel'

const OUTAGE_ROW_LIMIT = 6
const REGIME_CC = 'IR'
const PERSIA_LABEL = 'Persia'
const REGIME_LABEL = 'regime 👎'
const FLASH_DURATION_MS = 600
const STALE_AFTER_MS = 1_800_000
const MS_PER_HOUR = 3_600_000
const MS_PER_MINUTE = 60_000
const HOURS_PER_DAY = 24

export function OutagePanel(): React.ReactElement {
  const { items } = useOutageData()
  const seenIds = useRef<Set<string>>(new Set())
  const [flashIds, setFlashIds] = useState<Set<string>>(new Set())

  useEffect(() => {
    const isFirstSeed = seenIds.current.size === 0
    const newIds: string[] = []
    for (const o of items) {
      if (!seenIds.current.has(o.id)) {
        seenIds.current.add(o.id)
        if (!isFirstSeed) newIds.push(o.id)
      }
    }
    if (newIds.length > 0) setFlashIds(new Set(newIds))
  }, [items])

  useEffect(() => {
    if (flashIds.size === 0) return
    const t = setTimeout(() => setFlashIds(new Set()), FLASH_DURATION_MS)
    return () => clearTimeout(t)
  }, [flashIds])

  const recent = items.slice(0, OUTAGE_ROW_LIMIT)
  const now = Date.now()

  const lastTickAt = useFreshness((s) => s.ts.outage)
  const isStale =
    items.length === 0
      ? undefined
      : lastTickAt !== undefined && Date.now() - lastTickAt > STALE_AFTER_MS

  return (
    <Panel
      title="OUTAGES"
      subtitle="CF RADAR"
      source="cloudflare radar"
      accent="outage"
      rawHref="https://radar.cloudflare.com/outage-center"
      rawLabel="Cloudflare Radar Outage Center"
      isStale={isStale}
      lastTickAt={lastTickAt}
      batch
    >
      <table className={styles.table}>
        <thead>
          <tr>
            <th className={styles.cc}>CC</th>
            <th className={styles.info}>Cause</th>
            <th className={styles.state}>State</th>
            <th className={styles.ago}>Started</th>
          </tr>
        </thead>
        <tbody>
          {recent.map((o) => {
            const isFlashing = flashIds.has(o.id)
            return (
              <tr key={o.id} className={isFlashing ? styles.flash : undefined}>
                <td className={styles.cc}>{fmtCC(o.locations)}</td>
                <td
                  className={styles.info}
                  title={o.reason ?? o.outageType ?? ''}
                >
                  {isRegime(o.locations)
                    ? REGIME_LABEL
                    : fmtCause(o.reason, o.outageType)}
                </td>
                <td className={styles.state}>{fmtState(o.endDate)}</td>
                <td className={styles.ago}>{fmtAgo(o.startDate, now)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </Panel>
  )
}

OutagePanel.displayName = 'OutagePanel'

function isRegime(locations: string[] | undefined): boolean {
  return locations?.[0] === REGIME_CC
}

function fmtCC(locations: string[] | undefined): string {
  if (!locations || locations.length === 0) return '—'
  const raw = locations[0] ?? '—'
  const first = raw === REGIME_CC ? PERSIA_LABEL : raw
  if (locations.length === 1) return first
  return `${first} +${locations.length - 1}`
}

function fmtCause(
  reason: string | undefined,
  outageType: string | undefined
): string {
  if (reason?.trim()) return reason
  if (outageType?.trim()) return outageType
  return '—'
}

function fmtState(endDate: string | null | undefined): string {
  if (endDate === null || endDate === undefined) return 'active'
  const t = new Date(endDate).getTime()
  if (!Number.isFinite(t)) return 'ended'
  return 'ended'
}

function fmtAgo(iso: string | undefined, now: number): string {
  if (!iso) return '—'
  const t = new Date(iso).getTime()
  if (!Number.isFinite(t)) return '—'
  const diff = now - t
  if (diff < 0) return '—'
  if (diff < MS_PER_HOUR) {
    return `${Math.max(Math.floor(diff / MS_PER_MINUTE), 0)}m`
  }
  if (diff < HOURS_PER_DAY * MS_PER_HOUR) {
    return `${Math.floor(diff / MS_PER_HOUR)}h`
  }
  return `${Math.floor(diff / (HOURS_PER_DAY * MS_PER_HOUR))}d`
}
