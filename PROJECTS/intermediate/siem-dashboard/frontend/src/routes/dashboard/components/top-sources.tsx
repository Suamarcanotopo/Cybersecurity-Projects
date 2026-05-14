// ===================
// ©AngelaMos | 2026
// top-sources.tsx
//
// Horizontal bar list ranking the top source IPs by event count
//
// Bar width is calculated as a percentage of the highest count in the dataset.
// Empty and loading states are handled before rendering the bar list.
//
// Key components:
//   TopSources - ranked bar list panel, accepts TopSource[] and isLoading
//
// Connects to:
//   dashboard/index.tsx - receives top sources data and loading state
//   dashboard.types.ts - TopSource type
// ===================

import type { TopSource } from '@/api/types'
import styles from './top-sources.module.scss'

interface TopSourcesProps {
  data: TopSource[] | undefined
  isLoading: boolean
}

export function TopSources({
  data,
  isLoading,
}: TopSourcesProps): React.ReactElement {
  if (isLoading || !data) {
    return (
      <div className={styles.panel}>
        <h3 className={styles.title}>Top Sources</h3>
        <div className={styles.skeleton} />
      </div>
    )
  }

  if (data.length === 0) {
    return (
      <div className={styles.panel}>
        <h3 className={styles.title}>Top Sources</h3>
        <div className={styles.empty}>No data</div>
      </div>
    )
  }

  const maxCount = Math.max(...data.map((d) => d.count))

  return (
    <div className={styles.panel}>
      <h3 className={styles.title}>Top Sources</h3>
      <div className={styles.bars}>
        {data.map((source) => (
          <div key={source.source_ip} className={styles.barRow}>
            <span className={styles.barLabel}>{source.source_ip}</span>
            <div className={styles.barTrack}>
              <div
                className={styles.barFill}
                style={{ width: `${(source.count / maxCount) * 100}%` }}
              />
            </div>
            <span className={styles.barCount}>
              {source.count.toLocaleString()}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}
