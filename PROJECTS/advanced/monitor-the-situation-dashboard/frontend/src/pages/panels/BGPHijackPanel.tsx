// ©AngelaMos | 2026
// BGPHijackPanel.tsx

import { useEffect, useRef, useState } from 'react'
import { useBgpHijackData } from '@/api/hooks'
import { useFreshness } from '@/stores/freshness'
import styles from './BGPHijackPanel.module.scss'
import { Panel } from './Panel'

const HIJACK_ROW_LIMIT = 6
const FLASH_DURATION_MS = 600
const STALE_AFTER_MS = 600_000
const MS_PER_HOUR = 3_600_000
const MS_PER_MINUTE = 60_000
const HOURS_PER_DAY = 24

export function BGPHijackPanel(): React.ReactElement {
  const { items } = useBgpHijackData()
  const seenIds = useRef<Set<number>>(new Set())
  const [flashIds, setFlashIds] = useState<Set<number>>(new Set())

  useEffect(() => {
    const isFirstSeed = seenIds.current.size === 0
    const newIds: number[] = []
    for (const h of items) {
      if (!seenIds.current.has(h.id)) {
        seenIds.current.add(h.id)
        if (!isFirstSeed) newIds.push(h.id)
      }
    }
    if (newIds.length > 0) setFlashIds(new Set(newIds))
  }, [items])

  useEffect(() => {
    if (flashIds.size === 0) return
    const t = setTimeout(() => setFlashIds(new Set()), FLASH_DURATION_MS)
    return () => clearTimeout(t)
  }, [flashIds])

  const recent = items.slice(0, HIJACK_ROW_LIMIT)
  const now = Date.now()

  const lastTickAt = useFreshness((s) => s.ts.bgp)
  const isStale =
    items.length === 0
      ? undefined
      : lastTickAt !== undefined && Date.now() - lastTickAt > STALE_AFTER_MS

  return (
    <Panel
      title="BGP"
      subtitle="HIJACKS"
      source="cloudflare radar"
      accent="bgp"
      rawHref="https://radar.cloudflare.com/security"
      rawLabel="Cloudflare Radar"
      isStale={isStale}
      lastTickAt={lastTickAt}
      batch
    >
      <table className={styles.table}>
        <thead>
          <tr>
            <th className={styles.asn}>ASN</th>
            <th className={styles.cc}>CC</th>
            <th className={styles.isp}>ISP</th>
            <th className={styles.pfx}>Pfx</th>
            <th className={styles.ago}>Ago</th>
          </tr>
        </thead>
        <tbody>
          {recent.map((h) => {
            const isFlashing = flashIds.has(h.id)
            return (
              <tr key={h.id} className={isFlashing ? styles.flash : undefined}>
                <td className={styles.asn}>{fmtAsn(h.hijackerAsn)}</td>
                <td className={styles.cc}>{h.enrichment?.country ?? '—'}</td>
                <td className={styles.isp} title={h.enrichment?.isp ?? ''}>
                  {h.enrichment?.isp ?? '—'}
                </td>
                <td className={styles.pfx} title={(h.prefixes ?? []).join(', ')}>
                  {fmtPfx(h.prefixes)}
                </td>
                <td className={styles.ago}>{fmtAgo(h.detectedAt, now)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </Panel>
  )
}

BGPHijackPanel.displayName = 'BGPHijackPanel'

function fmtAsn(asn: number | undefined): string {
  if (!asn) return '—'
  return `AS${asn}`
}

function fmtPfx(prefixes: string[] | undefined): string {
  if (!prefixes || prefixes.length === 0) return '—'
  const first = prefixes[0] ?? '—'
  if (prefixes.length === 1) return first
  return `${first} +${prefixes.length - 1}`
}

function fmtAgo(iso: string | undefined, now: number): string {
  if (!iso || iso.startsWith('0001')) return '—'
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
