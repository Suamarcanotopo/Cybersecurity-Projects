// ===================
// ©AngelaMos | 2026
// event-timeline.tsx
//
// Animated area chart displaying event counts over time using @visx/xychart
//
// Renders an AnimatedAreaSeries on a time/linear scale with a monotone curve.
// The chart resizes responsively via ParentSize. A custom Tooltip shows the
// bucket timestamp and event count on hover.
//
// Key components:
//   EventTimeline - full-width area chart panel, accepts TimelineBucket[] and isLoading
//
// Connects to:
//   dashboard/index.tsx - receives timeline data and loading state
//   theme.ts - chartTheme for @visx styling
//   dashboard.types.ts - TimelineBucket type
// ===================

import { curveMonotoneX } from '@visx/curve'
import { ParentSize } from '@visx/responsive'
import {
  AnimatedAreaSeries,
  AnimatedAxis,
  AnimatedGrid,
  Tooltip,
  XYChart,
} from '@visx/xychart'
import type { TimelineBucket } from '@/api/types'
import { chartTheme } from '@/core/charts'
import styles from './event-timeline.module.scss'

interface EventTimelineProps {
  data: TimelineBucket[] | undefined
  isLoading: boolean
}

const xAccessor = (d: TimelineBucket) => new Date(d.bucket)
const yAccessor = (d: TimelineBucket) => d.count

export function EventTimeline({
  data,
  isLoading,
}: EventTimelineProps): React.ReactElement {
  if (isLoading || !data || data.length === 0) {
    return (
      <div className={styles.panel}>
        <h3 className={styles.title}>Event Timeline</h3>
        <div className={styles.skeleton} />
      </div>
    )
  }

  return (
    <div className={styles.panel}>
      <h3 className={styles.title}>Event Timeline</h3>
      <div className={styles.chart}>
        <ParentSize>
          {({ width }) => (
            <XYChart
              height={280}
              width={width}
              xScale={{ type: 'time' }}
              yScale={{ type: 'linear' }}
              theme={chartTheme}
            >
              <AnimatedGrid columns={false} numTicks={4} />
              <AnimatedAxis orientation="bottom" numTicks={6} />
              <AnimatedAxis orientation="left" numTicks={4} />
              <AnimatedAreaSeries
                dataKey="Events"
                data={data}
                xAccessor={xAccessor}
                yAccessor={yAccessor}
                fillOpacity={0.15}
                curve={curveMonotoneX}
              />
              <Tooltip
                snapTooltipToDatumX
                showVerticalCrosshair
                verticalCrosshairStyle={{ stroke: 'hsl(0, 0%, 30%)' }}
                style={{
                  backgroundColor: 'hsl(0, 0%, 14.1%)',
                  border: '1px solid hsl(0, 0%, 18%)',
                  borderRadius: '6px',
                  color: 'hsl(0, 0%, 98%)',
                  fontSize: '12px',
                  padding: '8px 12px',
                  boxShadow: 'none',
                }}
                renderTooltip={({ tooltipData }) => {
                  const datum = tooltipData?.nearestDatum?.datum as
                    | TimelineBucket
                    | undefined
                  if (!datum) return null
                  return (
                    <div>
                      <div
                        style={{ color: 'hsl(0, 0%, 53.7%)', marginBottom: 4 }}
                      >
                        {new Date(datum.bucket).toLocaleTimeString([], {
                          hour: '2-digit',
                          minute: '2-digit',
                        })}
                      </div>
                      <div>{datum.count.toLocaleString()} events</div>
                    </div>
                  )
                }}
              />
            </XYChart>
          )}
        </ParentSize>
      </div>
    </div>
  )
}
