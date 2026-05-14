// ©AngelaMos | 2026
// globeLayers.ts

import { useMemo } from 'react'
import { type GlobePointType, useGlobeEvents } from '@/stores/globeEvents'

const COLOR_BY_TYPE: Record<GlobePointType, string> = {
  iss: '#4ade80',
  ransomware: '#facc15',
  outage: '#f59e0b',
  hijack: '#ef4444',
  scan: '#60a5fa',
  earthquake: '#a855f7',
}

const ALTITUDE_BY_TYPE: Record<GlobePointType, number> = {
  iss: 0.08,
  earthquake: 0.06,
  hijack: 0.06,
  ransomware: 0.05,
  outage: 0.05,
  scan: 0.04,
}

const RADIUS_BY_TYPE: Record<GlobePointType, number> = {
  iss: 0.6,
  earthquake: 0.55,
  hijack: 0.55,
  ransomware: 0.5,
  outage: 0.5,
  scan: 0.45,
}

export interface GlobePointDatum {
  id: string
  type: GlobePointType
  lat: number
  lng: number
  color: string
  altitude: number
  radius: number
}

export interface GlobeRingDatum {
  id: string
  lat: number
  lng: number
}

export function useGlobePoints(): GlobePointDatum[] {
  const points = useGlobeEvents((s) => s.points)
  return useMemo(
    () =>
      points.map((p) => ({
        id: p.id,
        type: p.type,
        lat: p.lat,
        lng: p.lng,
        color: COLOR_BY_TYPE[p.type],
        altitude: ALTITUDE_BY_TYPE[p.type],
        radius: RADIUS_BY_TYPE[p.type],
      })),
    [points]
  )
}

export function useGlobeRings(): GlobeRingDatum[] {
  const rings = useGlobeEvents((s) => s.rings)
  return useMemo(
    () =>
      rings.map((r) => ({
        id: r.id,
        lat: r.lat,
        lng: r.lng,
      })),
    [rings]
  )
}
