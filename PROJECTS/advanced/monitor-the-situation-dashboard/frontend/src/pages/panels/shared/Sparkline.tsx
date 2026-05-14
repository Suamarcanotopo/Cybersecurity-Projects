// ©AngelaMos | 2026
// Sparkline.tsx

import { extent } from 'd3-array'
import { scaleLinear } from 'd3-scale'

const DEFAULT_WIDTH = 80
const DEFAULT_HEIGHT = 16
const STROKE_WIDTH = 1
const MIN_DATA_POINTS = 2

export interface SparklineProps {
  data: number[]
  width?: number
  height?: number
}

export function Sparkline({
  data,
  width = DEFAULT_WIDTH,
  height = DEFAULT_HEIGHT,
}: SparklineProps): React.ReactElement | null {
  if (data.length < MIN_DATA_POINTS) return null
  const [min, max] = extent(data)
  if (min === undefined || max === undefined) return null

  const x = scaleLinear()
    .domain([0, data.length - 1])
    .range([0, width])
  const y = scaleLinear().domain([min, max]).range([height, 0])

  const path = data
    .map((v, i) => `${i === 0 ? 'M' : 'L'}${x(i)},${y(v)}`)
    .join('')

  return (
    <svg width={width} height={height} role="img" aria-label="Trend sparkline">
      <title>Trend sparkline</title>
      <path
        d={path}
        fill="none"
        stroke="currentColor"
        strokeWidth={STROKE_WIDTH}
      />
    </svg>
  )
}

Sparkline.displayName = 'Sparkline'
