// ©AngelaMos | 2026
// prices.ts

import { create } from 'zustand'

export interface PriceTick {
  symbol: string
  price: string
  ts: number
  volume24h?: string
}

export interface MinuteBar {
  symbol: string
  minute: number
  open: string
  high: string
  low: string
  close: string
  volume?: string
}

interface PricesStore {
  latest: Record<string, PriceTick>
  history: Record<string, MinuteBar[]>
  pushTick: (t: PriceTick) => void
  pushMinute: (b: MinuteBar) => void
}

const HISTORY_CAP = 60

export const usePrices = create<PricesStore>((set) => ({
  latest: {},
  history: {},
  pushTick: (t) =>
    set((s) => ({
      latest: { ...s.latest, [t.symbol]: t },
    })),
  pushMinute: (b) =>
    set((s) => {
      const cur = s.history[b.symbol] ?? []
      const idx = cur.findIndex((c) => c.minute === b.minute)
      let next: MinuteBar[]
      if (idx >= 0) {
        next = [...cur.slice(0, idx), b, ...cur.slice(idx + 1)]
      } else {
        next = [...cur, b].slice(-HISTORY_CAP)
      }
      return { history: { ...s.history, [b.symbol]: next } }
    }),
}))
