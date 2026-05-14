// ©AngelaMos | 2026
// freshness.ts

import { create } from 'zustand'

export type SourceKey =
  | 'bgp'
  | 'outage'
  | 'kev'
  | 'ransomware'
  | 'dshield'
  | 'cve'
  | 'spacewx'
  | 'iss'
  | 'quake'
  | 'btc'
  | 'eth'
  | 'wiki'
  | 'ws'

interface FreshnessStore {
  ts: Partial<Record<SourceKey, number>>
  ping: (k: SourceKey) => void
}

export const useFreshness = create<FreshnessStore>((set) => ({
  ts: {},
  ping: (k) => set((s) => ({ ts: { ...s.ts, [k]: Date.now() } })),
}))
