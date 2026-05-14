// ©AngelaMos | 2026
// bgpHijack.ts

import { create } from 'zustand'
import type { BgpHijack } from '@/api/types'

interface BgpHijackStore {
  items: BgpHijack[]
  push: (item: BgpHijack) => void
  clear: () => void
}

const BGP_HIJACK_CAP = 100

export const useBgpHijackStore = create<BgpHijackStore>((set) => ({
  items: [],
  push: (item) =>
    set((s) => {
      const filtered = s.items.filter((i) => i.id !== item.id)
      return { items: [item, ...filtered].slice(0, BGP_HIJACK_CAP) }
    }),
  clear: () => set({ items: [] }),
}))
