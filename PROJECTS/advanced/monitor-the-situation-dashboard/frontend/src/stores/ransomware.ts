// ©AngelaMos | 2026
// ransomware.ts

import { create } from 'zustand'
import type { RansomwareVictim } from '@/api/types'

interface RansomwareStore {
  items: RansomwareVictim[]
  push: (item: RansomwareVictim) => void
  clear: () => void
}

const RANSOMWARE_CAP = 200

export function victimKey(v: RansomwareVictim): string {
  return `${v.post_title}|${v.group_name}|${v.discovered}`
}

export const useRansomwareStore = create<RansomwareStore>((set) => ({
  items: [],
  push: (item) =>
    set((s) => {
      const key = victimKey(item)
      const filtered = s.items.filter((i) => victimKey(i) !== key)
      return { items: [item, ...filtered].slice(0, RANSOMWARE_CAP) }
    }),
  clear: () => set({ items: [] }),
}))
