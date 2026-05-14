// ===================
// ©AngelaMos | 2026
// theme.ts
//
// Chart theme and color maps for @visx visualizations
//
// Builds the chartTheme using the app's dark palette for use with visx
// XYChart. Also exports SEVERITY_COLORS and STATUS_COLORS maps that map
// domain string values to HSL color strings for consistent color coding
// across charts and badge components.
//
// Key exports:
//   chartTheme - visx XYChart theme object
//   SEVERITY_COLORS - severity-to-HSL color map
//   STATUS_COLORS - alert status-to-HSL color map
//
// Connects to:
//   event-timeline.tsx - uses chartTheme
//   severity-chart.tsx - uses SEVERITY_COLORS
// ===================

import { buildChartTheme } from '@visx/xychart'

export const chartTheme = buildChartTheme({
  backgroundColor: 'transparent',
  colors: [
    'hsl(0, 84%, 39%)',
    'hsl(0, 72%, 60%)',
    'hsl(24, 95%, 63%)',
    'hsl(45, 93%, 57%)',
    'hsl(217, 91%, 70%)',
  ],
  gridColor: 'hsl(0, 0%, 18%)',
  gridColorDark: 'hsl(0, 0%, 11.1%)',
  svgLabelSmall: { fill: 'hsl(0, 0%, 53.7%)' },
  svgLabelBig: { fill: 'hsl(0, 0%, 70.6%)' },
  tickLength: 4,
})

export const SEVERITY_COLORS: Record<string, string> = {
  critical: 'hsl(0, 72%, 60%)',
  high: 'hsl(24, 95%, 63%)',
  medium: 'hsl(45, 93%, 57%)',
  low: 'hsl(217, 91%, 70%)',
  info: 'hsl(0, 0%, 53.7%)',
}

export const STATUS_COLORS: Record<string, string> = {
  new: 'hsl(217, 91%, 70%)',
  acknowledged: 'hsl(38, 92%, 60%)',
  investigating: 'hsl(263, 70%, 70%)',
  resolved: 'hsl(142, 76%, 46%)',
  false_positive: 'hsl(0, 0%, 53.7%)',
}
