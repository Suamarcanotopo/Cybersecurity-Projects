// ©AngelaMos | 2026
// globeEvents.ts

import { create } from 'zustand'

export type GlobePointType =
  | 'earthquake'
  | 'ransomware'
  | 'scan'
  | 'iss'
  | 'outage'
  | 'hijack'

export interface GlobePoint {
  id: string
  type: GlobePointType
  lat: number
  lng: number
  emittedAt: number
  meta?: Record<string, unknown>
}

export interface GlobeRing {
  id: string
  lat: number
  lng: number
  emittedAt: number
  ttlMs: number
}

interface GlobeStore {
  points: GlobePoint[]
  rings: GlobeRing[]
  focusEvent: GlobePoint | null
  pushPoint: (p: GlobePoint) => void
  pushRing: (r: GlobeRing) => void
  evict: (now: number) => void
  focus: (p: GlobePoint | null) => void
}

const POINT_TTL_MS = 15 * 60 * 1000
const POINT_CAP = 500
const RING_CAP = 200

export const useGlobeEvents = create<GlobeStore>((set) => ({
  points: [],
  rings: [],
  focusEvent: null,
  pushPoint: (p) =>
    set((s) => {
      const filtered = s.points.filter((existing) => existing.id !== p.id)
      return { points: [p, ...filtered].slice(0, POINT_CAP) }
    }),
  pushRing: (r) =>
    set((s) => ({
      rings: [...s.rings, r].slice(-RING_CAP),
    })),
  evict: (now) =>
    set((s) => ({
      points: s.points.filter((p) => now - p.emittedAt < POINT_TTL_MS),
      rings: s.rings.filter((r) => now - r.emittedAt < r.ttlMs),
    })),
  focus: (p) => set({ focusEvent: p }),
}))
