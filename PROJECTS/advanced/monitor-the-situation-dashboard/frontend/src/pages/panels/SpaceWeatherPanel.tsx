// ©AngelaMos | 2026
// SpaceWeatherPanel.tsx

import { useSpaceWeather } from '@/api/hooks'
import { Panel } from './Panel'
import styles from './SpaceWeatherPanel.module.scss'

const KP_SEGMENT_KEYS = [
  'kp-0',
  'kp-1',
  'kp-2',
  'kp-3',
  'kp-4',
  'kp-5',
  'kp-6',
  'kp-7',
  'kp-8',
] as const
const KP_ELEVATED_THRESHOLD = 7
const STALE_AFTER_MS = 600_000
const KP_DECIMALS = 1
const DENSITY_DECIMALS = 2
const XRAY_FLUX_DECIMALS = 1
const XRAY_ELEVATED_PATTERN = /^[MX]/

export function SpaceWeatherPanel(): React.ReactElement {
  const sw = useSpaceWeather()

  const lastTickAt = sw.ts ? new Date(sw.ts).getTime() : undefined
  const isStaleByTime =
    lastTickAt !== undefined && Date.now() - lastTickAt > STALE_AFTER_MS
  const kpElevated = sw.kp !== undefined && sw.kp >= KP_ELEVATED_THRESHOLD
  const xrayElevated =
    sw.xray_class !== undefined && XRAY_ELEVATED_PATTERN.test(sw.xray_class)
  return (
    <Panel
      title="SPACE WX"
      subtitle="SWPC"
      source="noaa swpc"
      accent="spacewx"
      rawHref="https://services.swpc.noaa.gov/"
      rawLabel="NOAA SWPC"
      isStale={lastTickAt === undefined ? undefined : isStaleByTime}
      lastTickAt={lastTickAt}
      batch
    >
      <div className={styles.row}>
        <span className={styles.label}>Kp Index</span>
        <span className={kpElevated ? styles.elevated : styles.value}>
          {sw.kp !== undefined ? sw.kp.toFixed(KP_DECIMALS) : '—'}
        </span>
        <KpBar kp={sw.kp} elevated={kpElevated} />
      </div>
      <div className={styles.row}>
        <span className={styles.label}>Solar Wind</span>
        <span className={styles.value}>
          {sw.speed_kms !== undefined ? `${Math.round(sw.speed_kms)} km/s` : '—'}
        </span>
        <span className={styles.value}>
          {sw.density !== undefined
            ? `${sw.density.toFixed(DENSITY_DECIMALS)} p/cc`
            : '—'}
        </span>
      </div>
      <div className={styles.row}>
        <span className={styles.label}>X-Ray Flux</span>
        <span className={xrayElevated ? styles.elevated : styles.value}>
          {sw.xray_flux !== undefined
            ? sw.xray_flux.toExponential(XRAY_FLUX_DECIMALS)
            : '—'}
        </span>
        <span className={xrayElevated ? styles.elevated : styles.classLetter}>
          {sw.xray_class ?? '—'}
        </span>
      </div>
    </Panel>
  )
}

SpaceWeatherPanel.displayName = 'SpaceWeatherPanel'

interface KpBarProps {
  kp: number | undefined
  elevated: boolean
}

function KpBar({ kp, elevated }: KpBarProps): React.ReactElement {
  return (
    <div className={styles.kpBar}>
      {KP_SEGMENT_KEYS.map((key, i) => {
        const filled = kp !== undefined && i < Math.floor(kp)
        let cls: string
        if (!filled) {
          cls = styles.kpSegEmpty
        } else if (elevated) {
          cls = styles.kpSegElevated
        } else {
          cls = styles.kpSegFilled
        }
        return <div key={key} className={cls} />
      })}
    </div>
  )
}
