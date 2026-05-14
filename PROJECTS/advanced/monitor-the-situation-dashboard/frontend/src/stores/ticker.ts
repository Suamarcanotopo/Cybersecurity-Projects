// ©AngelaMos | 2026
// ticker.ts

import { create } from 'zustand'

export interface TickerItem {
  id: string
  source: string
  headline: string
  ts: number
  href?: string
}

interface TickerStore {
  items: TickerItem[]
  push: (item: TickerItem) => void
  clear: () => void
}

const TICKER_CAP = 50

export const useTicker = create<TickerStore>((set) => ({
  items: [],
  push: (item) =>
    set((s) => {
      if (s.items.some((i) => i.id === item.id)) return s
      const next = [...s.items, item]
      return { items: next.slice(-TICKER_CAP) }
    }),
  clear: () => set({ items: [] }),
}))
