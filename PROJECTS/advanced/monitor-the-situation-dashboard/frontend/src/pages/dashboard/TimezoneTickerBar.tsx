// ©AngelaMos | 2026
// TimezoneTickerBar.tsx

import { useEffect, useState } from 'react'
import { useUIStore } from '@/stores/ui'
import styles from './TimezoneTickerBar.module.scss'

const CITIES = [
  { label: 'UTC', tz: 'UTC' },
  { label: 'LONDON', tz: 'Europe/London' },
  { label: 'NEW YORK', tz: 'America/New_York' },
  { label: 'LOS ANGELES', tz: 'America/Los_Angeles' },
  { label: 'SÃO PAULO', tz: 'America/Sao_Paulo' },
  { label: 'MOSCOW', tz: 'Europe/Moscow' },
  { label: 'DUBAI', tz: 'Asia/Dubai' },
  { label: 'MUMBAI', tz: 'Asia/Kolkata' },
  { label: 'HONG KONG', tz: 'Asia/Hong_Kong' },
  { label: 'TOKYO', tz: 'Asia/Tokyo' },
  { label: 'SYDNEY', tz: 'Australia/Sydney' },
] as const

const TICK_MS = 1_000

type CityState = 'awake' | 'office' | 'asleep'

function formatTime(d: Date, tz: string): string {
  return d.toLocaleTimeString('en-US', {
    timeZone: tz,
    hour12: false,
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}

function localHour(d: Date, tz: string): number {
  const h = d.toLocaleTimeString('en-US', {
    timeZone: tz,
    hour12: false,
    hour: '2-digit',
  })
  return Number.parseInt(h, 10)
}

function cityState(hour: number): CityState {
  if (hour >= 9 && hour <= 17) return 'office'
  if (hour >= 7 && hour <= 21) return 'awake'
  return 'asleep'
}

export function TimezoneTickerBar(): React.ReactElement | null {
  const [now, setNow] = useState(() => new Date())
  const isPresentation = useUIStore((s) => s.presentationMode)

  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), TICK_MS)
    return () => clearInterval(id)
  }, [])

  if (isPresentation) return null

  return (
    <div className={styles.bar}>
      <div className={styles.track}>
        {[0, 1].map((copy) => (
          <span key={copy} className={styles.copy} aria-hidden={copy === 1}>
            {CITIES.map((city) => {
              const state = cityState(localHour(now, city.tz))
              const DOT_CLS: Record<CityState, string> = {
                office: styles.dotOffice,
                awake: styles.dotAwake,
                asleep: styles.dotAsleep,
              }
              const dotCls = `${styles.dot} ${DOT_CLS[state]}`
              return (
                <span key={city.label} className={styles.city}>
                  <span className={dotCls} aria-hidden />
                  <span className={styles.label}>{city.label}</span>
                  <span className={styles.time}>{formatTime(now, city.tz)}</span>
                </span>
              )
            })}
          </span>
        ))}
      </div>
    </div>
  )
}

TimezoneTickerBar.displayName = 'TimezoneTickerBar'
