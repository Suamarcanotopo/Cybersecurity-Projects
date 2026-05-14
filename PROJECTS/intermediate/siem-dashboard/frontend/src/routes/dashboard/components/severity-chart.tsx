// ===================
// ©AngelaMos | 2026
// severity-chart.tsx
//
// Donut chart with legend showing alert counts per severity level
//
// Uses @visx/shape Pie inside an SVG scaled with ParentSize. Arc colors map
// to SEVERITY_COLORS from the chart theme. The center of the donut shows the
// total alert count. A legend list to the right labels each severity with its
// color dot and count.
//
// Key components:
//   SeverityChart - donut + legend panel, accepts SeverityCount[] and isLoading
//
// Connects to:
//   dashboard/index.tsx - receives severity data and loading state
//   theme.ts - SEVERITY_COLORS
//   config.ts - SEVERITY_LABELS for display strings
// ===================

import { Group } from '@visx/group'
import { ParentSize } from '@visx/responsive'
import { Pie } from '@visx/shape'
import type { SeverityCount } from '@/api/types'
import { SEVERITY_LABELS } from '@/config'
import { SEVERITY_COLORS } from '@/core/charts'
import styles from './severity-chart.module.scss'

interface SeverityChartProps {
  data: SeverityCount[] | undefined
  isLoading: boolean
}

export function SeverityChart({
  data,
  isLoading,
}: SeverityChartProps): React.ReactElement {
  if (isLoading || !data) {
    return (
      <div className={styles.panel}>
        <h3 className={styles.title}>Severity Breakdown</h3>
        <div className={styles.skeleton} />
      </div>
    )
  }

  const total = data.reduce((sum, d) => sum + d.count, 0)

  return (
    <div className={styles.panel}>
      <h3 className={styles.title}>Severity Breakdown</h3>
      <div className={styles.content}>
        <div className={styles.chartWrap}>
          <ParentSize>
            {({ width }) => {
              const size = Math.min(width, 200)
              const radius = size / 2
              return (
                <svg
                  width={size}
                  height={size}
                  role="img"
                  aria-label="Severity breakdown donut chart"
                >
                  <title>Severity breakdown donut chart</title>
                  <Group top={radius} left={radius}>
                    <Pie
                      data={data}
                      pieValue={(d) => d.count}
                      outerRadius={radius}
                      innerRadius={radius * 0.6}
                      cornerRadius={2}
                      padAngle={0.02}
                    >
                      {(pie) =>
                        pie.arcs.map((arc) => (
                          <path
                            key={arc.data.severity}
                            d={pie.path(arc) ?? ''}
                            fill={
                              SEVERITY_COLORS[arc.data.severity] ??
                              'hsl(0, 0%, 30%)'
                            }
                          />
                        ))
                      }
                    </Pie>
                    <text
                      textAnchor="middle"
                      dy={-6}
                      fill="hsl(0, 0%, 98%)"
                      fontSize={22}
                      fontWeight={600}
                    >
                      {total.toLocaleString()}
                    </text>
                    <text
                      textAnchor="middle"
                      dy={14}
                      fill="hsl(0, 0%, 53.7%)"
                      fontSize={10}
                      letterSpacing="0.05em"
                    >
                      TOTAL
                    </text>
                  </Group>
                </svg>
              )
            }}
          </ParentSize>
        </div>
        <div className={styles.legend}>
          {data.map((item) => (
            <div key={item.severity} className={styles.legendItem}>
              <span
                className={styles.legendDot}
                style={{
                  backgroundColor: SEVERITY_COLORS[item.severity],
                }}
              />
              <span className={styles.legendLabel}>
                {SEVERITY_LABELS[item.severity] ?? item.severity}
              </span>
              <span className={styles.legendValue}>
                {item.count.toLocaleString()}
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
