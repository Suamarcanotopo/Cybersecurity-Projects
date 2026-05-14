// ©AngelaMos | 2026
// KEVPanel.tsx

import { useKevData } from '@/api/hooks'
import { useFreshness } from '@/stores/freshness'
import styles from './KEVPanel.module.scss'
import { Panel } from './Panel'

const KEV_ROW_LIMIT = 6
const STALE_AFTER_MS = 86_400_000

export function KEVPanel(): React.ReactElement {
  const { items } = useKevData()
  const recent = items.slice(0, KEV_ROW_LIMIT)

  const lastTickAt = useFreshness((s) => s.ts.kev)
  const isStale =
    items.length === 0
      ? undefined
      : lastTickAt !== undefined && Date.now() - lastTickAt > STALE_AFTER_MS

  return (
    <Panel
      title="KEV"
      subtitle="CISA EXPLOITED"
      source="cisa.gov"
      accent="kev"
      rawHref="https://www.cisa.gov/known-exploited-vulnerabilities-catalog"
      rawLabel="CISA KEV catalog"
      isStale={isStale}
      lastTickAt={lastTickAt}
      batch
    >
      <table className={styles.table}>
        <thead>
          <tr>
            <th className={styles.cveId}>CVE</th>
            <th className={styles.vp}>Vendor · Product</th>
            <th className={styles.date}>Added</th>
          </tr>
        </thead>
        <tbody>
          {recent.map((k) => (
            <tr key={k.cveID}>
              <td className={styles.cveId}>{k.cveID}</td>
              <td className={styles.vp}>
                {k.vendorProject} · {k.product}
              </td>
              <td className={styles.date}>{k.dateAdded}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </Panel>
  )
}

KEVPanel.displayName = 'KEVPanel'
