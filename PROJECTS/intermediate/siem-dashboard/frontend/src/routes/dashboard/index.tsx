// ===================
// ©AngelaMos | 2026
// index.tsx
//
// Dashboard route that composes the four main analytics panels
//
// Fires all four dashboard queries in parallel and passes data and loading
// state down to each panel component. The two chart panels sit side-by-side
// in a row below the full-width timeline.
//
// Key components:
//   Component - lazy-loaded dashboard page; displayName "Dashboard"
//
// Connects to:
//   useDashboard.ts - useDashboardOverview, useTimeline, useSeverityBreakdown, useTopSources
//   stat-cards.tsx, event-timeline.tsx, severity-chart.tsx, top-sources.tsx - panel components
// ===================

import {
  useDashboardOverview,
  useSeverityBreakdown,
  useTimeline,
  useTopSources,
} from '@/api/hooks'
import { EventTimeline } from './components/event-timeline'
import { SeverityChart } from './components/severity-chart'
import { StatCards } from './components/stat-cards'
import { TopSources } from './components/top-sources'
import styles from './dashboard.module.scss'

export function Component(): React.ReactElement {
  const overview = useDashboardOverview()
  const timeline = useTimeline()
  const severity = useSeverityBreakdown()
  const topSources = useTopSources()

  return (
    <div className={styles.page}>
      <StatCards data={overview.data} isLoading={overview.isLoading} />
      <EventTimeline data={timeline.data} isLoading={timeline.isLoading} />
      <div className={styles.row}>
        <SeverityChart data={severity.data} isLoading={severity.isLoading} />
        <TopSources data={topSources.data} isLoading={topSources.isLoading} />
      </div>
    </div>
  )
}

Component.displayName = 'Dashboard'
