// ©AngelaMos | 2026
// useCoinbasePrices.ts

import { useEffect } from 'react'
import { useSnapshot } from '@/api/snapshot'
import { isValidCoinbasePriceMap } from '@/api/types'
import { type MinuteBar, type PriceTick, usePrices } from '@/stores/prices'

const EMPTY_BARS: MinuteBar[] = []

interface CoinbasePricesData {
  latest: PriceTick | undefined
  history: MinuteBar[]
}

export function useCoinbasePrices(symbol: string): CoinbasePricesData {
  const { data } = useSnapshot()
  const latest = usePrices((s) => s.latest[symbol])
  const historyRaw = usePrices((s) => s.history[symbol])
  const history = historyRaw ?? EMPTY_BARS
  const pushTick = usePrices((s) => s.pushTick)

  const priceMap = data?.coinbase_price
  const seed = isValidCoinbasePriceMap(priceMap) ? priceMap[symbol] : undefined
  useEffect(() => {
    if (!seed) return
    pushTick({
      symbol: seed.symbol,
      ts: new Date(seed.ts).getTime(),
      price: seed.price,
      volume24h: seed.volume_24h,
    })
  }, [seed, pushTick])

  return { latest, history }
}
