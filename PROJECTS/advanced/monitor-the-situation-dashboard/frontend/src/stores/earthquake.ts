// ©AngelaMos | 2026
// earthquake.ts

import { create } from 'zustand'
import type { EarthquakePayload } from '@/api/types'

interface EarthquakeStore {
  items: EarthquakePayload[]
  push: (item: EarthquakePayload) => void
  clear: () => void
}

const EARTHQUAKE_CAP = 100

export const useEarthquakeStore = create<EarthquakeStore>((set) => ({
  items: [],
  push: (item) =>
    set((s) => {
      const filtered = s.items.filter((i) => i.id !== item.id)
      return { items: [item, ...filtered].slice(0, EARTHQUAKE_CAP) }
    }),
  clear: () => set({ items: [] }),
}))
