// ©AngelaMos | 2026
// outage.ts

import { create } from 'zustand'
import type { InternetOutage } from '@/api/types'

interface OutageStore {
  items: InternetOutage[]
  push: (item: InternetOutage) => void
  clear: () => void
}

const OUTAGE_CAP = 50

export const useOutageStore = create<OutageStore>((set) => ({
  items: [],
  push: (item) =>
    set((s) => {
      const filtered = s.items.filter((i) => i.id !== item.id)
      return { items: [item, ...filtered].slice(0, OUTAGE_CAP) }
    }),
  clear: () => set({ items: [] }),
}))
