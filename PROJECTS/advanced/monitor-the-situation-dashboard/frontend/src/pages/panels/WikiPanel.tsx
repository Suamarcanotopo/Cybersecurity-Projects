// ©AngelaMos | 2026
// WikiPanel.tsx

import { useFreshness } from '@/stores/freshness'
import { useTicker } from '@/stores/ticker'
import { Panel } from './Panel'
import styles from './WikiPanel.module.scss'

const MAX_ITEMS = 6
const STALE_AFTER_MS = 3_600_000
const MS_PER_SECOND = 1_000
const SECONDS_PER_MINUTE = 60
const SECONDS_PER_HOUR = 3_600

export function WikiPanel(): React.ReactElement {
  const all = useTicker((s) => s.items)
  const items = all
    .filter((i) => i.source === 'Wikipedia')
    .slice(-MAX_ITEMS)
    .reverse()

  const lastTickAt = useFreshness((s) => s.ts.wiki)
  const isStale =
    items.length === 0
      ? undefined
      : lastTickAt !== undefined && Date.now() - lastTickAt > STALE_AFTER_MS

  return (
    <Panel
      title="News"
      subtitle="Wikipedia ITN"
      source="en.wikipedia.org"
      accent="wiki"
      isStale={isStale}
      lastTickAt={lastTickAt}
      batch
    >
      <div className={styles.list}>
        {items.length === 0 ? (
          <div className={styles.empty}>—</div>
        ) : (
          items.map((item) => (
            <div key={item.id} className={styles.row}>
              {item.href ? (
                <a
                  className={styles.headline}
                  href={item.href}
                  target="_blank"
                  rel="noreferrer noopener"
                >
                  {item.headline}
                </a>
              ) : (
                <span className={styles.headline}>{item.headline}</span>
              )}
              <span className={styles.ts}>{fmtRel(item.ts)}</span>
            </div>
          ))
        )}
      </div>
    </Panel>
  )
}

WikiPanel.displayName = 'WikiPanel'

function fmtRel(ts: number): string {
  const diff = (Date.now() - ts) / MS_PER_SECOND
  if (diff < SECONDS_PER_MINUTE) return `${Math.floor(diff)}s`
  if (diff < SECONDS_PER_HOUR) return `${Math.floor(diff / SECONDS_PER_MINUTE)}m`
  return `${Math.floor(diff / SECONDS_PER_HOUR)}h`
}
