// ©AngelaMos | 2026
// geo.types.ts

import { z } from 'zod'

export const issPositionSchema = z.object({
  latitude: z.number(),
  longitude: z.number(),
  altitude: z.number(),
  velocity: z.number(),
  timestamp: z.number(),
  fetched_at: z.string().optional(),
})

export type IssPosition = z.infer<typeof issPositionSchema>

export const earthquakePropertiesSchema = z.object({
  mag: z.number().nullable().optional(),
  place: z.string().nullable().optional(),
  time: z.number().optional(),
  updated: z.number().optional(),
  alert: z.string().nullable().optional(),
  tsunami: z.number().optional(),
  url: z.string().optional(),
  type: z.string().optional(),
})

export type EarthquakeProperties = z.infer<typeof earthquakePropertiesSchema>

export const earthquakePayloadSchema = z.object({
  id: z.string(),
  geometry: z.object({ coordinates: z.array(z.number()).optional() }).optional(),
  properties: earthquakePropertiesSchema.optional(),
})

export type EarthquakePayload = z.infer<typeof earthquakePayloadSchema>

export const internetOutageSchema = z.object({
  id: z.string(),
  startDate: z.string().optional(),
  endDate: z.string().nullable().optional(),
  locations: z.array(z.string()).optional(),
  asns: z.array(z.number()).optional(),
  reason: z.string().optional(),
  outageType: z.string().optional(),
})

export type InternetOutage = z.infer<typeof internetOutageSchema>

export const isValidIssPosition = (data: unknown): data is IssPosition => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return issPositionSchema.safeParse(data).success
}

export const isValidEarthquakePayload = (
  data: unknown
): data is EarthquakePayload => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return earthquakePayloadSchema.safeParse(data).success
}

export const isValidInternetOutage = (data: unknown): data is InternetOutage => {
  if (data === null || data === undefined || typeof data !== 'object')
    return false
  return internetOutageSchema.safeParse(data).success
}
