// ©AngelaMos | 2026
// BottomTicker.tsx

import { useLayoutEffect, useRef } from 'react'
import { useTicker } from '@/stores/ticker'
import { useUIStore } from '@/stores/ui'
import styles from './BottomTicker.module.scss'

const MS_PER_SECOND = 1_000
const SECONDS_PER_MINUTE = 60
const SECONDS_PER_HOUR = 3_600
const COPY_COUNT = 3
const TICKER_PX_PER_SECOND = 90
const MIN_DURATION_S = 30

function measureDuration(el: HTMLDivElement): number {
  const w = el.scrollWidth
  const vw = window.innerWidth
  return Math.max(MIN_DURATION_S, (w + vw) / TICKER_PX_PER_SECOND)
}

export function BottomTicker(): React.ReactElement | null {
  const items = useTicker((s) => s.items)
  const isPresentation = useUIStore((s) => s.presentationMode)
  const trackRef = useRef<HTMLDivElement | null>(null)

  useLayoutEffect(() => {
    const el = trackRef.current
    if (!el) return

    const update = (): void => {
      el.style.animationDuration = `${measureDuration(el)}s`
    }

    update()

    const ro = new ResizeObserver(update)
    ro.observe(el)
    window.addEventListener('resize', update)

    return () => {
      ro.disconnect()
      window.removeEventListener('resize', update)
    }
  }, [])

  if (isPresentation) return null
  if (items.length === 0) return <div className={styles.ticker} />

  return (
    <div className={styles.ticker}>
      <div ref={trackRef} className={styles.track}>
        {Array.from({ length: COPY_COUNT }, (_, r) =>
          items.map((item, i) => (
            <span key={`${item.id}-${r}-${i}`} className={styles.item}>
              <span className={styles.source}>{item.source}</span>
              <span className={styles.headline}>{item.headline}</span>
              <span className={styles.ts}>{formatRel(item.ts)}</span>
            </span>
          ))
        )}
      </div>
    </div>
  )
}

BottomTicker.displayName = 'BottomTicker'

function formatRel(ts: number): string {
  const diff = (Date.now() - ts) / MS_PER_SECOND
  if (diff < SECONDS_PER_MINUTE) return `${Math.floor(diff)}s`
  if (diff < SECONDS_PER_HOUR) return `${Math.floor(diff / SECONDS_PER_MINUTE)}m`
  return `${Math.floor(diff / SECONDS_PER_HOUR)}h`
}
