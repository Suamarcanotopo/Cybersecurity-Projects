// ©AngelaMos | 2026
// BTCPanel.tsx

import { useCoinbasePrices } from '@/api/hooks'
import { usePriceFlash } from '@/lib/usePriceFlash'
import { useThrottledValue } from '@/lib/useThrottledValue'
import styles from './BTCPanel.module.scss'
import { Panel } from './Panel'

const SYMBOL = 'BTC-USD'
const PERCENT_DECIMALS = 2
const PRICE_DECIMALS = 2
const STALE_AFTER_MS = 60_000
const PRICE_THROTTLE_MS = 1_500

export function BTCPanel(): React.ReactElement {
  const { latest, history } = useCoinbasePrices(SYMBOL)

  const rawPriceNum = latest ? Number(latest.price) : null
  const priceNum = useThrottledValue(rawPriceNum, PRICE_THROTTLE_MS)
  const closes = history.map((b) => Number(b.close))
  const pct1h = computeChangePct(closes)
  const { dir: flashDir, key: flashKey } = usePriceFlash(priceNum)

  const lastTickAt = latest?.ts
  const isStale =
    latest === undefined ? undefined : Date.now() - latest.ts > STALE_AFTER_MS

  const priceClass = [
    styles.price,
    flashDir === 'up'
      ? styles.flashUp
      : flashDir === 'down'
        ? styles.flashDown
        : '',
  ]
    .filter(Boolean)
    .join(' ')

  return (
    <Panel
      title="BTC"
      subtitle="USD"
      source="coinbase"
      accent="btc"
      rawHref="https://www.coinbase.com/price/bitcoin"
      rawLabel="Coinbase BTC"
      isStale={isStale}
      lastTickAt={lastTickAt}
    >
      <div className={styles.hero}>
        <span key={flashKey} className={priceClass}>
          {fmtPrice(priceNum)}
        </span>
        <span className={styles.unit}>USD</span>
      </div>
      <div className={styles.changes}>
        <ChangeRow label="1H" pct={pct1h} />
      </div>
    </Panel>
  )
}

BTCPanel.displayName = 'BTCPanel'

function ChangeRow({
  label,
  pct,
}: {
  label: string
  pct: number | null
}): React.ReactElement {
  const isUp = pct !== null && pct >= 0
  return (
    <div className={styles.change}>
      <span className={styles.changeLabel}>{label}</span>
      <span className={styles.changeValue}>
        {pct === null ? (
          '—'
        ) : (
          <>
            <span className={isUp ? styles.up : styles.down}>
              {isUp ? '△' : '▽'}
            </span>
            {` ${Math.abs(pct).toFixed(PERCENT_DECIMALS)} %`}
          </>
        )}
      </span>
    </div>
  )
}

function computeChangePct(closes: number[]): number | null {
  if (closes.length < 2) return null
  const first = closes[0]
  const last = closes[closes.length - 1]
  if (
    first === undefined ||
    last === undefined ||
    !Number.isFinite(first) ||
    !Number.isFinite(last) ||
    first === 0
  ) {
    return null
  }
  return ((last - first) / first) * 100
}

function fmtPrice(n: number | null): string {
  if (n === null || !Number.isFinite(n)) return '—'
  return n.toLocaleString(undefined, {
    minimumFractionDigits: PRICE_DECIMALS,
    maximumFractionDigits: PRICE_DECIMALS,
  })
}
