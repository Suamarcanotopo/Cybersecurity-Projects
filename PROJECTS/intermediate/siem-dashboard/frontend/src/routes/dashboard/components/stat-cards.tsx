// ===================
// ©AngelaMos | 2026
// stat-cards.tsx
//
// Four KPI metric cards showing total events, alerts, open alerts, and critical count
//
// Extracts the critical severity count from the overview's severity_breakdown
// array. Renders skeleton placeholder cards while data is loading.
//
// Key components:
//   StatCards - grid of four metric cards, accepts DashboardOverview and isLoading
//
// Connects to:
//   dashboard/index.tsx - receives overview data and loading state
//   dashboard.types.ts - DashboardOverview type
// ===================

import type { DashboardOverview } from '@/api/types'
import styles from './stat-cards.module.scss'

interface StatCardsProps {
  data: DashboardOverview | undefined
  isLoading: boolean
}

export function StatCards({
  data,
  isLoading,
}: StatCardsProps): React.ReactElement {
  const critical =
    data?.severity_breakdown?.find((s) => s.severity === 'critical')?.count ?? 0

  const cards = [
    { label: 'Total Events', value: data?.total_events ?? 0 },
    { label: 'Total Alerts', value: data?.total_alerts ?? 0 },
    { label: 'Open Alerts', value: data?.open_alerts ?? 0 },
    { label: 'Critical', value: critical },
  ]

  if (isLoading) {
    return (
      <div className={styles.grid}>
        {Array.from({ length: 4 }, (_, i) => (
          <div key={`skel-${i}`} className={styles.card}>
            <div className={styles.skeleton} />
          </div>
        ))}
      </div>
    )
  }

  return (
    <div className={styles.grid}>
      {cards.map((card) => (
        <div key={card.label} className={styles.card}>
          <span className={styles.value}>{card.value.toLocaleString()}</span>
          <span className={styles.label}>{card.label}</span>
        </div>
      ))}
    </div>
  )
}
