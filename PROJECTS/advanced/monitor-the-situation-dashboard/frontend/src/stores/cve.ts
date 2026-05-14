// ©AngelaMos | 2026
// cve.ts

import { create } from 'zustand'
import type { CveEvent } from '@/api/types'

interface CveStore {
  items: CveEvent[]
  push: (item: CveEvent) => void
  clear: () => void
}

const CVE_CAP = 500

export const useCveStore = create<CveStore>((set) => ({
  items: [],
  push: (item) =>
    set((s) => {
      const filtered = s.items.filter((i) => i.CveID !== item.CveID)
      return { items: [item, ...filtered].slice(0, CVE_CAP) }
    }),
  clear: () => set({ items: [] }),
}))
