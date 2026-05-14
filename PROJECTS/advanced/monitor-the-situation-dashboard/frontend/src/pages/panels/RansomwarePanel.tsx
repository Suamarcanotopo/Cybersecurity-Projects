// ©AngelaMos | 2026
// RansomwarePanel.tsx

import { useEffect, useRef, useState } from 'react'
import { useRansomwareData } from '@/api/hooks'
import { useFreshness } from '@/stores/freshness'
import { victimKey } from '@/stores/ransomware'
import { Panel } from './Panel'
import styles from './RansomwarePanel.module.scss'

const VICTIM_ROW_LIMIT = 6
const FLASH_DURATION_MS = 600
const STALE_AFTER_MS = 3_600_000
const MS_PER_HOUR = 3_600_000
const MS_PER_MINUTE = 60_000
const HOURS_PER_DAY = 24

export function RansomwarePanel(): React.ReactElement {
  const { items } = useRansomwareData()
  const seenKeys = useRef<Set<string>>(new Set())
  const [flashKeys, setFlashKeys] = useState<Set<string>>(new Set())

  useEffect(() => {
    const isFirstSeed = seenKeys.current.size === 0
    const newKeys: string[] = []
    for (const v of items) {
      const k = victimKey(v)
      if (!seenKeys.current.has(k)) {
        seenKeys.current.add(k)
        if (!isFirstSeed) newKeys.push(k)
      }
    }
    if (newKeys.length > 0) setFlashKeys(new Set(newKeys))
  }, [items])

  useEffect(() => {
    if (flashKeys.size === 0) return
    const t = setTimeout(() => setFlashKeys(new Set()), FLASH_DURATION_MS)
    return () => clearTimeout(t)
  }, [flashKeys])

  const recent = items.slice(0, VICTIM_ROW_LIMIT)
  const now = Date.now()

  const lastTickAt = useFreshness((s) => s.ts.ransomware)
  const isStale =
    items.length === 0
      ? undefined
      : lastTickAt !== undefined && Date.now() - lastTickAt > STALE_AFTER_MS

  return (
    <Panel
      title="RANSOMWARE"
      subtitle="VICTIMS"
      source="ransomware.live"
      accent="ransomware"
      rawHref="https://ransomware.live/"
      rawLabel="ransomware.live"
      isStale={isStale}
      lastTickAt={lastTickAt}
      batch
    >
      <table className={styles.table}>
        <thead>
          <tr>
            <th className={styles.victim}>Victim</th>
            <th className={styles.group}>Group</th>
            <th className={styles.cc}>CC</th>
            <th className={styles.ago}>Ago</th>
          </tr>
        </thead>
        <tbody>
          {recent.map((v) => {
            const key = victimKey(v)
            const isFlashing = flashKeys.has(key)
            return (
              <tr key={key} className={isFlashing ? styles.flash : undefined}>
                <td className={styles.victim} title={v.post_title}>
                  {v.post_title}
                </td>
                <td className={styles.group}>{v.group_name}</td>
                <td className={styles.cc}>{v.country ?? '—'}</td>
                <td className={styles.ago}>{fmtAgo(v.discovered, now)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </Panel>
  )
}

RansomwarePanel.displayName = 'RansomwarePanel'

function fmtAgo(iso: string, now: number): string {
  const t = new Date(iso).getTime()
  if (!Number.isFinite(t)) return '—'
  const diff = now - t
  if (diff < MS_PER_HOUR) {
    return `${Math.max(Math.floor(diff / MS_PER_MINUTE), 0)}m`
  }
  if (diff < HOURS_PER_DAY * MS_PER_HOUR) {
    return `${Math.floor(diff / MS_PER_HOUR)}h`
  }
  return `${Math.floor(diff / (HOURS_PER_DAY * MS_PER_HOUR))}d`
}
