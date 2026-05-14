// ©AngelaMos | 2026
// globeCamera.ts

import type { MutableRefObject } from 'react'
import type { GlobeMethods } from 'react-globe.gl'

const DEFAULT_PAN_DURATION_MS = 1200
const DEFAULT_FOCUS_ALTITUDE = 1.8

export type GlobeRef = MutableRefObject<GlobeMethods | undefined>

export function panTo(
  ref: GlobeRef,
  lat: number,
  lng: number,
  durationMs: number = DEFAULT_PAN_DURATION_MS,
  altitude: number = DEFAULT_FOCUS_ALTITUDE
): void {
  ref.current?.pointOfView({ lat, lng, altitude }, durationMs)
}
